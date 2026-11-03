import Foundation
import KonomiKit
import Observation

/// Live ニコニコ実況 / NX-Jikkyo comment client.
///
/// The connection sequence is the one `LiveCommentManager.ts` uses:
/// `GET /api/channels/{id}/jikkyo` → watch session socket (`startWatching`,
/// `seat` → `keepSeat`, `ping` → `pong`, `room` / `messageServer`) → comment
/// session socket (thread request, past comments up to `rf:0`, then one chat
/// per comment). Comments are filtered by `JikkyoCommentAcceptance` and
/// `CommentMuteFilter`, added to the panel list in 333 ms batches and drawn by
/// the overlay only while playback is running.
@MainActor
@Observable
final class LiveCommentSession {
    let channel: LiveChannel
    private let model: AppModel
    private let overlay: CommentOverlayModel

    /// Comment list of the panel, oldest first (at most 500, like the web).
    private(set) var comments: [CommentRow] = []
    /// Short session message shown above the list (errors, notices).
    private(set) var statusMessage: String?
    /// The watch room is known, so a comment can be posted.
    private(set) var isConnected = false
    /// Incremented for every accepted post, so the form can clear itself.
    private(set) var successfulPostCount = 0
    private(set) var service: JikkyoService = .nxjikkyo

    @ObservationIgnored private var info: JikkyoWebSocketInfo?
    @ObservationIgnored private var watchTask: URLSessionWebSocketTask?
    @ObservationIgnored private var commentTask: URLSessionWebSocketTask?
    @ObservationIgnored private var watchReceiveTask: Task<Void, Never>?
    @ObservationIgnored private var commentReceiveTask: Task<Void, Never>?
    @ObservationIgnored private var keepSeatTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var emitTask: Task<Void, Never>?

    /// Bumped on every teardown; receive loops of an old socket compare it and
    /// stop acting on the session.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var isStopped = true
    @ObservationIgnored private var isReconnecting = false

    @ObservationIgnored private var roomReceived = false
    @ObservationIgnored private var vposBaseTime: Date?
    @ObservationIgnored private var threadID = ""
    @ObservationIgnored private var yourPostKey: String?

    @ObservationIgnored private var initialCommentsReceived = false
    @ObservationIgnored private var initialRows: [CommentRow] = []
    @ObservationIgnored private var freshRows: [CommentRow] = []
    @ObservationIgnored private var nextRowID = 0
    @ObservationIgnored private var pendingPost: PendingPost?

    private struct PendingPost {
        let text: String
        let color: String
        let position: CommentDanmaku.Position
        let size: CommentDanmaku.Size
        let baseTime: Date
    }

    private static let maxCommentCount = 500

    init(model: AppModel, channel: LiveChannel, overlay: CommentOverlayModel) {
        self.model = model
        self.channel = channel
        self.overlay = overlay
    }

    // MARK: - Lifecycle

    func start() {
        guard isStopped else { return }
        isStopped = false
        comments = []
        statusMessage = nil
        successfulPostCount = 0
        Task { await self.connect() }
    }

    /// Cancels every timer, closes both sockets and stops reconnecting.
    func stop() {
        isStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        teardown()
    }

    // MARK: - Connection

    private func connect() async {
        guard let client = model.client else {
            statusMessage = JikkyoMessages.webSocketInfoUnavailable
            return
        }

        let info: JikkyoWebSocketInfo
        do {
            info = try await client.jikkyoWebSocketInfo(channelID: channel.displayChannelID)
        } catch {
            guard !isStopped else { return }
            statusMessage = JikkyoMessages.webSocketInfoUnavailable
            return
        }
        guard !isStopped else { return }
        guard let watchURL = info.watchSessionURLValue else {
            statusMessage = JikkyoMessages.channelNotSupported
            return
        }

        self.info = info
        var selectedURL = watchURL
        var selectedService = JikkyoService(watchSessionURL: info.watchSessionURL)

        // 「可能であればニコニコ実況にコメントする」がオンのとき、Nicolive の
        // 視聴セッション URL があればそちらを使う。取得できなかった理由のうち
        // NX-Jikkyo 専用チャンネル・未ログイン・未連携は通知しない (web と同じ)。
        if model.settings.preferPostingToNicolive {
            if let nicoliveURL = info.nicoliveWatchSessionURLValue {
                selectedURL = nicoliveURL
                selectedService = JikkyoService(watchSessionURL: info.nicoliveWatchSessionURL)
            } else if info.isNXJikkyoExclusive || model.user == nil
                || model.user?.isNiconicoLinked == false {
                // Expected fallback; stay quiet.
            } else if let error = info.nicoliveWatchSessionError {
                statusMessage = JikkyoMessages.nicoliveFallbackNotice(error: error)
            }
        }

        service = selectedService
        openWatchSocket(selectedURL)
    }

    private func openWatchSocket(_ url: URL) {
        teardown()

        let task = URLSession.shared.webSocketTask(with: url)
        watchTask = task
        task.resume()
        send(.startWatching)

        let epoch = self.epoch
        watchReceiveTask = Task { [weak self] in
            await self?.receiveWatch(epoch: epoch, task: task)
        }
    }

    private func openCommentSocket(_ url: URL) {
        guard commentTask == nil else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        commentTask = task
        task.resume()

        // The comment server sends nothing until it receives the thread
        // request, wrapped in the rs:0 … rf:0 ping sandwich.
        let request = JikkyoCommentSessionRequest(threadID: threadID, threadKey: yourPostKey)
        Task {
            try? await task.send(.string(request.jsonString))
        }

        initialCommentsReceived = false
        initialRows.removeAll()

        let epoch = self.epoch
        commentReceiveTask = Task { [weak self] in
            await self?.receiveComments(epoch: epoch, task: task)
        }
    }

    /// Reconnect = tear down both sockets and timers, then start again from
    /// step 1. Only one reconnect task exists at a time.
    private func scheduleReconnect(after delay: TimeInterval) {
        guard !isStopped, reconnectTask == nil, !isReconnecting else { return }
        isReconnecting = true
        statusMessage = JikkyoMessages.reconnecting(service: service)

        reconnectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.reconnectTask = nil
            self.teardown()
            self.isReconnecting = false
            await self.connect()
        }
    }

    private func teardown() {
        epoch &+= 1

        watchReceiveTask?.cancel()
        watchReceiveTask = nil
        commentReceiveTask?.cancel()
        commentReceiveTask = nil
        keepSeatTask?.cancel()
        keepSeatTask = nil
        emitTask?.cancel()
        emitTask = nil

        watchTask?.cancel(with: .goingAway, reason: nil)
        watchTask = nil
        commentTask?.cancel(with: .goingAway, reason: nil)
        commentTask = nil

        roomReceived = false
        isConnected = false
        vposBaseTime = nil
        threadID = ""
        yourPostKey = nil
        initialCommentsReceived = false
        initialRows.removeAll()
        freshRows.removeAll()
        pendingPost = nil
    }

    // MARK: - Watch session

    private func send(_ request: JikkyoWatchSessionRequest) {
        guard let watchTask else { return }
        Task {
            try? await watchTask.send(.string(request.jsonString))
        }
    }

    private func receiveWatch(epoch: Int, task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard !Task.isCancelled, epoch == self.epoch, watchTask === task else { return }
                let text: String
                switch message {
                case .string(let string):
                    text = string
                case .data(let data):
                    guard let decoded = String(data: data, encoding: .utf8) else { continue }
                    text = decoded
                @unknown default:
                    continue
                }
                handleWatchMessage(text)
            } catch {
                guard !Task.isCancelled, epoch == self.epoch, watchTask === task else { return }
                handleWatchClosed(error: error)
                return
            }
        }
    }

    private func handleWatchMessage(_ text: String) {
        guard let message = try? JikkyoWatchSessionMessage.decode(text) else { return }

        switch message {
        case .seat(let seat):
            startKeepSeat(interval: JikkyoSessionTiming.keepSeatInterval(seat: seat))

        case .ping:
            send(.pong)

        case .room(let room):
            roomReceived = true
            isConnected = true
            vposBaseTime = room.vposBaseTime
            threadID = room.threadID
            yourPostKey = room.yourPostKey
            if let raw = room.messageServerURL, let url = URL(string: raw) {
                openCommentSocket(url)
            } else if let url = info?.commentSessionURLValue {
                openCommentSocket(url)
            }

        case .messageServer(let server):
            // Nicolive's NDGR message server is not a WebSocket, so the
            // comment session always connects to NX-Jikkyo (web does the same).
            roomReceived = true
            isConnected = true
            vposBaseTime = server.vposBaseTime
            threadID = ""
            yourPostKey = server.hashedUserID.map { "nicolive:" + $0 }
            if let url = info?.commentSessionURLValue {
                openCommentSocket(url)
            }

        case .error(let error):
            if error.isCommentPostError {
                if pendingPost != nil {
                    failPendingPost(with: JikkyoMessages.commentPostError(code: error.code))
                }
            } else {
                statusMessage = JikkyoMessages.watchSessionError(
                    service: service,
                    code: error.code
                )
                scheduleReconnect(after: JikkyoSessionTiming.reconnectDelay)
            }

        case .reconnect:
            scheduleReconnect(after: 0)

        case .disconnect(let disconnect):
            statusMessage = JikkyoMessages.disconnectReason(
                service: service,
                reason: disconnect.reason
            )
            scheduleReconnect(after: JikkyoSessionTiming.reconnectDelay)

        case .postCommentResult(let result):
            finishPendingPost(result)

        case .statistics, .unknown:
            break
        }
    }

    private func handleWatchClosed(error: Error) {
        let code = String((error as NSError).code)
        // A disconnect message (or an earlier failure) already explained the
        // reason; a reconnect is pending, so keep that message.
        if reconnectTask == nil {
            statusMessage = JikkyoMessages.watchSessionClosed(service: service, code: code)
        }
        scheduleReconnect(after: JikkyoSessionTiming.reconnectDelay)
    }

    private func startKeepSeat(interval: TimeInterval) {
        guard keepSeatTask == nil else { return }
        keepSeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.send(.keepSeat)
            }
        }
    }

    // MARK: - Comment session

    private func receiveComments(epoch: Int, task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard !Task.isCancelled, epoch == self.epoch, commentTask === task else { return }
                let text: String
                switch message {
                case .string(let string):
                    text = string
                case .data(let data):
                    guard let decoded = String(data: data, encoding: .utf8) else { continue }
                    text = decoded
                @unknown default:
                    continue
                }
                handleCommentMessage(text)
            } catch {
                guard !Task.isCancelled, epoch == self.epoch, commentTask === task else { return }
                let code = String((error as NSError).code)
                if reconnectTask == nil {
                    statusMessage = JikkyoMessages.commentSessionClosed(code: code)
                }
                scheduleReconnect(after: JikkyoSessionTiming.reconnectDelay)
                return
            }
        }
    }

    private func handleCommentMessage(_ text: String) {
        guard let message = try? JikkyoCommentSessionMessage.decode(text) else { return }

        switch message {
        case .thread(let result):
            if !result.isSuccess {
                // The web client only logs this; the socket usually closes next.
                statusMessage = JikkyoMessages.commentSessionClosed(
                    code: String(result.resultCode)
                )
            }

        case .ping:
            if message.isInitialCommentsEnd, !initialCommentsReceived {
                initialCommentsReceived = true
                // The web client clears the list and fills it with the past
                // comments of the new connection (Comment.vue).
                comments = initialRows
                if comments.count > Self.maxCommentCount {
                    comments.removeFirst(comments.count - Self.maxCommentCount)
                }
                initialRows.removeAll()
            }

        case .chat(let chat):
            let ownNiconicoUserID = model.user?.niconicoUserID
            guard JikkyoCommentAcceptance.accepts(
                chat,
                isInitialComments: !initialCommentsReceived,
                ownNiconicoUserID: ownNiconicoUserID
            ) else { return }
            guard !CommentMuteFilter.isMuted(
                chat,
                options: CommentMuteFilter.Options(settings: model.settings)
            ) else { return }

            let danmaku = CommentDanmaku(chat: chat)
            let row = makeRow(danmaku: danmaku, date: chat.date)
            if initialCommentsReceived {
                freshRows.append(row)
                scheduleFlush()
            } else {
                // Past comments of the connection fill the list but are never
                // drawn on the video.
                initialRows.append(row)
            }

        case .unknown:
            break
        }
    }

    // MARK: - List and overlay

    private func makeRow(danmaku: CommentDanmaku, date: Double?) -> CommentRow {
        nextRowID += 1
        let timestamp = date.map { Date(timeIntervalSince1970: $0) } ?? Date()
        return CommentRow(
            id: nextRowID,
            danmaku: danmaku,
            displayTime: Formatters.clock(
                timestamp,
                use28HourClock: model.settings.use28HourClock
            )
        )
    }

    private func scheduleFlush() {
        guard emitTask == nil else { return }
        emitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(JikkyoSessionTiming.commentEmitInterval))
            guard let self, !Task.isCancelled else { return }
            self.emitTask = nil
            self.flushFreshComments()
        }
    }

    private func flushFreshComments() {
        let rows = freshRows
        freshRows.removeAll()
        guard !rows.isEmpty else { return }

        appendRows(rows)

        // New comments are drawn only while the video is playing.
        guard model.playback.isPlaying else { return }
        for row in rows {
            overlay.emit(row.danmaku)
        }
    }

    private func appendRows(_ rows: [CommentRow]) {
        guard !rows.isEmpty else { return }
        comments.append(contentsOf: rows)
        if comments.count > Self.maxCommentCount {
            comments.removeFirst(comments.count - Self.maxCommentCount)
        }
    }

    /// Removes a muted user's comments from the panel (the context menu).
    func removeComments(from authorID: String) {
        guard !authorID.isEmpty else { return }
        comments.removeAll { $0.authorID == authorID }
        initialRows.removeAll { $0.authorID == authorID }
        freshRows.removeAll { $0.authorID == authorID }
    }

    // MARK: - Posting

    /// Sends a comment on the watch socket. Returns false when the comment was
    /// rejected before sending (the reason is in `statusMessage`).
    @discardableResult
    func postComment(
        text rawText: String,
        color: String,
        position: CommentDanmaku.Position,
        size: CommentDanmaku.Size
    ) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        guard roomReceived, watchTask != nil, let baseTime = vposBaseTime else {
            statusMessage = JikkyoMessages.commentPostNotConnected
            return false
        }

        // 「可能であればニコニコ実況にコメントする」がオンのときの案内。
        // 投稿自体は NX-Jikkyo にフォールバックして続行する。
        if model.settings.preferPostingToNicolive {
            if model.user == nil {
                statusMessage = JikkyoMessages.loginRequiredForNicolive
            } else if model.user?.isNiconicoLinked == false {
                statusMessage = JikkyoMessages.niconicoLinkRequiredForNicolive
            }
        }

        if service == .nicolive, model.user?.niconicoUserPremium == false {
            if position == .top || position == .bottom {
                statusMessage = JikkyoMessages.premiumRequiredForPosition
                return false
            }
            if size == .big {
                statusMessage = JikkyoMessages.premiumRequiredForSize
                return false
            }
        }

        pendingPost = PendingPost(
            text: text,
            color: color,
            position: position,
            size: size,
            baseTime: baseTime
        )
        let vpos = JikkyoPostComment.vpos(now: Date(), vposBaseTime: baseTime)
        send(.postComment(
            JikkyoPostComment(
                text: text,
                hexColor: color,
                danmakuPosition: position,
                size: size,
                vpos: vpos
            )
        ))
        return true
    }

    private func finishPendingPost(_ result: JikkyoPostCommentResult) {
        guard let draft = pendingPost else { return }
        pendingPost = nil

        let now = Date()
        let chat = result.chat
        let time = chat?.time ?? max(now.timeIntervalSince(draft.baseTime), 0)
        let authorID = model.user?.niconicoUserID.map(String.init) ?? ""
        let danmaku = CommentDanmaku.ownComment(
            text: draft.text,
            color: draft.color,
            position: draft.position,
            size: draft.size,
            time: time,
            authorID: authorID,
            commentNumber: chat?.number,
            date: chat?.date ?? now.timeIntervalSince1970
        )

        appendRows([makeRow(danmaku: danmaku, date: chat?.date ?? now.timeIntervalSince1970)])
        overlay.emit(danmaku)
        successfulPostCount += 1
    }

    private func failPendingPost(with message: String) {
        pendingPost = nil
        statusMessage = message
    }
}
