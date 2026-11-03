import Foundation
import SwiftUI
import UIKit
import KonomiKit

/// A recorded file that finished downloading, ready to be shared or saved.
struct DownloadedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let filename: String
}

/// Downloads a recorded file with the bearer token, reporting progress.
///
/// Recordings are often several gigabytes, so the file is streamed to disk by a
/// URLSession download task rather than read through memory.
enum VideoFileDownload {
    @MainActor
    static func download(
        video: RecordedProgram,
        client: APIClient,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> DownloadedFile {
        var request = URLRequest(url: client.videoDownloadURL(id: video.id))
        request.timeoutInterval = 60
        if let token = client.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let delegate = DownloadProgressDelegate { fraction in
            Task { @MainActor in progress(min(fraction, 0.99)) }
        }
        let (temporaryURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        delegate.invalidate()

        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw APIError.httpStatus(http.statusCode, nil)
        }

        let filename = self.filename(response: http, video: video)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        progress(1)
        return DownloadedFile(url: destination, filename: filename)
    }

    private static func filename(response: HTTPURLResponse, video: RecordedProgram) -> String {
        if let disposition = response.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filename(fromContentDisposition: disposition) {
            return name
        }
        if let path = video.recordedVideo.filePath, !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty {
                return name
            }
        }
        return "video\(video.id).m2ts"
    }

    private static func filename(fromContentDisposition header: String) -> String? {
        guard let range = header.range(of: "filename=") else { return nil }
        var name = String(header[range.upperBound...])
        if let semicolon = name.firstIndex(of: ";") {
            name = String(name[..<semicolon])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        name = (name as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

/// Forwards the download task's progress.
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let onProgress = self.onProgress
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        lock.withLock { self.observation = observation }
    }

    func invalidate() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }
}

/// Presents the system share sheet (保存 / 他のアプリで開く) for a downloaded file.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // Nothing to update: the sheet is created with the file it shares.
    }
}
