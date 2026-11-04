import Foundation
import UIKit
import WebKit

/// Configuration of one data broadcasting page load.
///
/// It is injected into the page with a `WKUserScript` at document start, so the
/// native settings are the source of truth: the page never persists them
/// itself.
struct BMLPageConfiguration: Sendable {
    /// `display_channel_id` (e.g. `gr011`).
    var channelID: String
    var networkID: Int
    var serviceID: Int
    /// The API quality path component (e.g. `1080p-60fps`).
    var quality: String
    /// データ放送からのインターネットアクセス.
    var internetAccess: Bool
    /// Receiver information as web-bml's NVRAM values (base64 of the raw
    /// bytes, keyed by `zipcode` / `prefecture` / `regioncode`).
    var receiverInfo: [String: String]
    /// The KonomiTV server the `/api/...` requests are proxied to.
    var serverBaseURL: URL
    var token: String?
}

/// The WKWebView that renders the data broadcasting (BML) page.
///
/// It sits above the video and below the caption / comment overlays, is fully
/// transparent (`videoPlaneModeEnabled` clips web-bml's own background around
/// the video plane, and the native video shows through) and only receives
/// touches while the BML screen is on screen.
///
/// The page is recreated for every channel / quality change, which is also how
/// the web client restarts its BML browser.
@MainActor
final class DataBroadcastingWebView: UIView {
    /// Custom scheme the bundle and the API are served from: no CORS, no
    /// mixed content, and the authentication token never reaches the page.
    static let scheme = "konomitv-bml"
    static let host = "app"
    static let pageURL = URL(string: "\(scheme)://\(host)/index.html")!

    private weak var controller: DataBroadcastingController?
    private var webView: WKWebView?
    private var schemeHandler: BMLSchemeHandler?
    private var messageRouter: BMLMessageRouter?

    init(controller: DataBroadcastingController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = "bml.webView"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Page lifecycle

    /// Starts a new page for the given channel configuration.
    func load(configuration: BMLPageConfiguration) {
        unload()

        guard let bundle = Bundle.main.url(forResource: "BML", withExtension: nil) else {
            controller?.pageDidFail("データ放送のページが見つかりません。")
            return
        }
        let schemeHandler = BMLSchemeHandler(
            bundleDirectory: bundle,
            serverBaseURL: configuration.serverBaseURL,
            token: configuration.token
        )
        self.schemeHandler = schemeHandler

        let userContentController = WKUserContentController()
        let router = BMLMessageRouter(controller: controller)
        userContentController.add(router, name: BMLMessageRouter.name)
        userContentController.addUserScript(
            WKUserScript(
                source: Self.configurationScript(configuration),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        messageRouter = router

        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.setURLSchemeHandler(schemeHandler, forURLScheme: Self.scheme)
        webConfiguration.userContentController = userContentController
        webConfiguration.allowsInlineMediaPlayback = true
        // BML sound (ROMSOUND / network content) may start without a gesture;
        // iOS still requires one for the first AudioContext, which the BML
        // screen provides because it only receives touches while visible.
        webConfiguration.mediaTypesRequiringUserActionForPlayback = []
        webConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: bounds, configuration: webConfiguration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.accessibilityIdentifier = "bml.webView"
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.isUserInteractionEnabled = isUserInteractionEnabled
        addSubview(webView)
        self.webView = webView
        webView.load(URLRequest(url: Self.pageURL))
    }

    /// Tears the page down and cancels the API requests it started.
    func unload() {
        schemeHandler?.cancelAll()
        schemeHandler = nil
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: BMLMessageRouter.name)
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        messageRouter = nil
    }

    /// The player changed size (rotation, Split View, Stage Manager).
    func resize(to size: CGSize) {
        call("KonomiBML.resize(\(Int(size.width.rounded())), \(Int(size.height.rounded())))")
    }

    /// Enables or disables touches (the BML screen only takes touches while it
    /// is on screen).
    func setInputEnabled(_ enabled: Bool) {
        isUserInteractionEnabled = enabled
        webView?.isUserInteractionEnabled = enabled
    }

    /// Evaluates a `KonomiBML` call in the page.
    /// The completion-handler form: the async overload's non-optional `Any`
    /// result traps when the script evaluates to undefined, which most of these
    /// calls do.
    func call(_ javascript: String) {
        webView?.evaluateJavaScript(javascript, completionHandler: nil)
    }

    // MARK: - Configuration

    private static func configurationScript(_ configuration: BMLPageConfiguration) -> String {
        var config: [String: Any] = [
            "channelId": configuration.channelID,
            "networkId": configuration.networkID,
            "serviceId": configuration.serviceID,
            "quality": configuration.quality,
            "apiBase": "\(scheme)://\(host)/api",
            "internetAccess": configuration.internetAccess,
            "receiverInfo": configuration.receiverInfo,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__KonomiBMLConfig = \(json);"
    }
}

// MARK: - Navigation

extension DataBroadcastingWebView: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // `KonomiBML.start()` uses the configuration injected at document
            // start.
            self.call("KonomiBML.start()")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.controller?.pageDidFail(message)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            self.controller?.pageDidFail(message)
        }
    }
}

// MARK: - Message bridge

/// Receives the page's `window.webkit.messageHandlers.bml` messages.
///
/// WebKit delivers script messages on the main thread, so the handler can hop
/// onto the main actor synchronously.
final class BMLMessageRouter: NSObject, WKScriptMessageHandler, @unchecked Sendable {
    static let name = "bml"

    private weak var controller: DataBroadcastingController?

    @MainActor
    init(controller: DataBroadcastingController?) {
        self.controller = controller
        super.init()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        MainActor.assumeIsolated {
            guard let body = body as? [String: Any] else { return }
            controller?.handle(message: body)
        }
    }
}

// MARK: - Scheme handler

/// Serves the data broadcasting bundle and proxies the page's `/api/...`
/// requests to the KonomiTV server.
///
/// The PSI/SI archived data stream is endless, so the response body is
/// forwarded chunk by chunk (`WKURLSchemeTask.didReceive(_:)`) while the
/// upstream `URLSession` task runs; `webView(_:stop:)` cancels it. WebKit
/// calls both scheme handler methods on the main thread, and a task must never
/// be used after it was stopped (that raises an Objective-C exception), so
/// every callback checks the task's state first.
final class BMLSchemeHandler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate, @unchecked Sendable {
    private let bundleDirectory: URL
    private let serverBaseURL: URL
    private let token: String?

    /// One entry per running upstream request, keyed by its task identifier.
    private var requests: [Int: BMLProxyRequest] = [:]
    private var session: URLSession?

    init(bundleDirectory: URL, serverBaseURL: URL, token: String?) {
        self.bundleDirectory = bundleDirectory
        self.serverBaseURL = serverBaseURL
        self.token = token
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        // Delegate callbacks are delivered on the main queue, so the
        // WKURLSchemeTask calls stay on the main thread and keep their order.
        self.session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: .main
        )
    }

    // MARK: WKURLSchemeHandler

    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            self.start(urlSchemeTask)
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            self.stop(urlSchemeTask)
        }
    }

    /// Cancels every request and drops the session (the whole page is going
    /// away, so nothing else may arrive).
    @MainActor
    func cancelAll() {
        for request in requests.values {
            request.cancel()
        }
        requests.removeAll()
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: Requests

    @MainActor
    private func start(_ schemeTask: WKURLSchemeTask) {
        guard let url = schemeTask.request.url else {
            schemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if url.path.hasPrefix("/api/") {
            startProxy(schemeTask, url: url)
        } else {
            serveBundleFile(schemeTask, url: url)
        }
    }

    @MainActor
    private func serveBundleFile(_ schemeTask: WKURLSchemeTask, url: URL) {
        let relativePath = url.path == "/" || url.path.isEmpty ? "index.html" : String(url.path.dropFirst())
        let fileURL = bundleDirectory.appendingPathComponent(relativePath)
        guard fileURL.standardizedFileURL.path.hasPrefix(bundleDirectory.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            schemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let headers = [
            "Content-Type": Self.mimeType(for: fileURL.pathExtension),
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
        ]
        if let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) {
            schemeTask.didReceive(response)
        }
        schemeTask.didReceive(data)
        schemeTask.didFinish()
    }

    @MainActor
    private func startProxy(_ schemeTask: WKURLSchemeTask, url: URL) {
        guard let upstreamURL = Self.upstreamURL(base: serverBaseURL, requestURL: url) else {
            schemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var request = URLRequest(url: upstreamURL)
        let incoming = schemeTask.request
        request.httpMethod = incoming.httpMethod ?? "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType = incoming.value(forHTTPHeaderField: "Content-Type") {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = incoming.httpBody {
            request.httpBody = body
        } else if let stream = incoming.httpBodyStream {
            request.httpBodyStream = stream
        }

        guard let session else {
            schemeTask.didFailWithError(URLError(.unknown))
            return
        }
        let dataTask = session.dataTask(with: request)
        let proxy = BMLProxyRequest(schemeTask: schemeTask, dataTask: dataTask)
        requests[dataTask.taskIdentifier] = proxy
        dataTask.resume()
    }

    @MainActor
    private func stop(_ schemeTask: WKURLSchemeTask) {
        guard let proxy = requests.first(where: { $0.value.schemeTask === schemeTask })?.value else {
            return
        }
        proxy.cancel()
        requests.removeValue(forKey: proxy.dataTask.taskIdentifier)
    }

    @MainActor
    private func finish(_ dataTask: URLSessionTask) -> BMLProxyRequest? {
        guard let proxy = requests[dataTask.taskIdentifier] else { return nil }
        requests.removeValue(forKey: dataTask.taskIdentifier)
        return proxy
    }

    // MARK: URLSessionDataDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            if let proxy = self.requests[dataTask.taskIdentifier] {
                proxy.receive(response: response)
            }
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            self.requests[dataTask.taskIdentifier]?.receive(data: data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        MainActor.assumeIsolated {
            guard let proxy = self.finish(task) else { return }
            if let error, !proxy.isStopped {
                proxy.fail(error)
            } else {
                proxy.complete()
            }
        }
    }

    // MARK: Helpers

    private static func upstreamURL(base: URL, requestURL: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let incoming = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + incoming.percentEncodedPath
        components.percentEncodedQuery = incoming.percentEncodedQuery
        components.fragment = nil
        return components.url
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

/// One proxied API request: the upstream `URLSession` task and the WebKit task
/// it feeds.
///
/// All of its methods run on the main thread. `isStopped`/`isFinished` exist
/// because calling `WKURLSchemeTask` after WebKit stopped it raises an
/// Objective-C exception.
@MainActor
final class BMLProxyRequest {
    let schemeTask: WKURLSchemeTask
    let dataTask: URLSessionDataTask
    private(set) var isStopped = false
    private var isFinished = false
    private var didSendResponse = false

    init(schemeTask: WKURLSchemeTask, dataTask: URLSessionDataTask) {
        self.schemeTask = schemeTask
        self.dataTask = dataTask
    }

    func receive(response: URLResponse) {
        guard !isStopped, !isFinished, !didSendResponse else { return }
        didSendResponse = true
        guard let url = schemeTask.request.url else { return }
        schemeTask.didReceive(Self.convert(response, url: url))
    }

    /// The upstream response carries the server's URL; WebKit expects the
    /// response of a scheme task to describe the requested URL. The headers are
    /// reduced to the ones a fetched resource needs.
    private static func convert(_ response: URLResponse, url: URL) -> URLResponse {
        guard let http = response as? HTTPURLResponse else {
            return URLResponse(
                url: url,
                mimeType: response.mimeType,
                expectedContentLength: -1,
                textEncodingName: response.textEncodingName
            )
        }
        let allowed: Set<String> = [
            "content-type", "content-length", "cache-control", "content-language",
            "content-location", "last-modified", "date", "pragma", "expires",
            "age", "accept-ranges", "authentication-info",
        ]
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, allowed.contains(name.lowercased()) else { continue }
            headers[name] = "\(value)"
        }
        return HTTPURLResponse(
            url: url,
            statusCode: http.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) ?? URLResponse(
            url: url,
            mimeType: http.mimeType,
            expectedContentLength: Int(http.expectedContentLength),
            textEncodingName: nil
        )
    }

    func receive(data: Data) {
        guard !isStopped, !isFinished, !data.isEmpty else { return }
        schemeTask.didReceive(data)
    }

    func complete() {
        guard !isStopped, !isFinished else { return }
        isFinished = true
        schemeTask.didFinish()
    }

    func fail(_ error: any Error) {
        guard !isStopped, !isFinished else { return }
        isFinished = true
        schemeTask.didFailWithError(error)
    }

    func cancel() {
        guard !isStopped else { return }
        isStopped = true
        dataTask.cancel()
    }
}
