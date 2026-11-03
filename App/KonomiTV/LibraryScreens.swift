import SwiftUI
import KonomiKit

/// マイリスト: the recorded programs of the My List, newest added first.
struct MyListScreen: View {
    let model: AppModel

    @State private var items: [RecordedProgram] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// The loaded programs, restricted to what is still in the My List, so a
    /// removal on a detail screen is reflected without waiting for a reload.
    private var visibleItems: [RecordedProgram] {
        let ids = Set(model.mylistVideoIDs)
        return items.filter { ids.contains($0.id) && !model.isVideoDeleted(id: $0.id) }
    }

    var body: some View {
        LibraryVideoGrid(
            model: model,
            items: visibleItems,
            gridIdentifier: "mylist.grid",
            itemPrefix: "mylist.item",
            isLoading: isLoading,
            errorMessage: errorMessage,
            emptyTitle: "マイリストは空です",
            emptySystemImage: "bookmark",
            progress: { _ in nil },
            removeTitle: "マイリストから削除",
            onRemove: { video in
                model.removeFromMylist(videoID: video.id)
                items.removeAll { $0.id == video.id }
            },
            onRetry: { Task { await load() } }
        )
        .navigationTitle("マイリスト")
        .task { await load() }
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        let ids = model.mylistVideoIDs
        guard !ids.isEmpty else {
            items = []
            return
        }

        do {
            let result = try await client.videos(ids: ids)
            guard !Task.isCancelled else { return }
            items = result.recordedPrograms.filter { !model.isVideoDeleted(id: $0.id) }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// 視聴履歴: the recorded programs of the watch history, last watched first.
struct WatchedHistoryScreen: View {
    let model: AppModel

    @State private var items: [RecordedProgram] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    /// The loaded programs, restricted to what is still in the watch history.
    private var visibleItems: [RecordedProgram] {
        let ids = Set(model.historyVideoIDs)
        return items.filter { ids.contains($0.id) && !model.isVideoDeleted(id: $0.id) }
    }

    var body: some View {
        LibraryVideoGrid(
            model: model,
            items: visibleItems,
            gridIdentifier: "history.grid",
            itemPrefix: "history.item",
            isLoading: isLoading,
            errorMessage: errorMessage,
            emptyTitle: "まだ視聴履歴がありません",
            emptySystemImage: "clock.arrow.circlepath",
            progress: { video in resumeProgress(for: video) },
            removeTitle: "視聴履歴から削除",
            onRemove: { video in
                model.removeWatchedHistory(videoID: video.id)
                items.removeAll { $0.id == video.id }
            },
            onRetry: { Task { await load() } }
        )
        .navigationTitle("視聴履歴")
        .task { await load() }
    }

    private func resumeProgress(for video: RecordedProgram) -> Double? {
        guard let entry = model.watchedHistoryEntry(videoID: video.id),
              video.duration > 0 else {
            return nil
        }
        return min(max(entry.lastPlaybackPosition / video.duration, 0), 1)
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        let ids = model.historyVideoIDs
        guard !ids.isEmpty else {
            items = []
            return
        }

        do {
            let result = try await client.videos(ids: ids)
            guard !Task.isCancelled else { return }
            items = result.recordedPrograms.filter { !model.isVideoDeleted(id: $0.id) }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// Grid of recorded programs used by マイリスト and 視聴履歴, with a context
/// menu to remove an entry.
struct LibraryVideoGrid: View {
    let model: AppModel
    let items: [RecordedProgram]
    let gridIdentifier: String
    let itemPrefix: String
    let isLoading: Bool
    let errorMessage: String?
    let emptyTitle: String
    let emptySystemImage: String
    let progress: (RecordedProgram) -> Double?
    let removeTitle: String
    let onRemove: (RecordedProgram) -> Void
    let onRetry: () -> Void

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if !items.isEmpty {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(items) { video in
                        NavigationLink(value: SectionRoute.video(video)) {
                            VideoCard(
                                video: video,
                                thumbnailURL: model.client?.thumbnailURL(videoID: video.id),
                                progress: progress(video)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(itemPrefix).\(video.id)")
                        .contextMenu {
                            Button(removeTitle, role: .destructive) {
                                onRemove(video)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier(gridIdentifier)
        } else if isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("ビデオを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    onRetry()
                }
            }
        } else {
            ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
        }
    }
}
