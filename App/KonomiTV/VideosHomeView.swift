import SwiftUI
import KonomiKit

/// ビデオ: home screen with 新着の録画番組, 視聴履歴 and マイリスト.
struct VideosHomeView: View {
    let model: AppModel

    @State private var recent: [RecordedProgram] = []
    @State private var mylist: [RecordedProgram] = []
    @State private var history: [RecordedProgram] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("ビデオ")
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && recent.isEmpty {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, recent.isEmpty {
            ContentUnavailableView {
                Label("ビデオを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }

                // Saved videos stay playable while the server is unreachable.
                if model.offline.hasContent {
                    NavigationLink(value: SectionRoute.offlineList) {
                        Text("オフライン保存を見る")
                    }
                    .accessibilityIdentifier("videos.offlineLink")
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(
                        title: "新着の録画番組",
                        programs: recent,
                        route: .videoList,
                        moreIdentifier: "videos.more.recent",
                        itemPrefix: "videos.recent"
                    )

                    NavigationLink(value: SectionRoute.seriesList) {
                        Label("シリーズ", systemImage: "rectangle.stack")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                    .accessibilityIdentifier("videos.seriesLink")

                    if !history.isEmpty {
                        section(
                            title: "視聴履歴",
                            programs: history,
                            route: .history,
                            moreIdentifier: "videos.more.history",
                            itemPrefix: "videos.history",
                            progress: { video in
                                resumeProgress(for: video)
                            }
                        )
                    }

                    if !mylist.isEmpty {
                        section(
                            title: "マイリスト",
                            programs: mylist,
                            route: .mylist,
                            moreIdentifier: "videos.more.mylist",
                            itemPrefix: "videos.mylist"
                        )
                    }
                }
                .padding(.vertical, 16)
            }
            .accessibilityIdentifier("videos.home")
        }
    }

    private func section(
        title: String,
        programs: [RecordedProgram],
        route: SectionRoute,
        moreIdentifier: String,
        itemPrefix: String,
        progress: ((RecordedProgram) -> Double?)? = nil
    ) -> some View {
        VideosHomeSection(
            model: model,
            title: title,
            programs: programs,
            route: route,
            moreIdentifier: moreIdentifier,
            itemPrefix: itemPrefix,
            progress: progress
        )
    }

    private func resumeProgress(for video: RecordedProgram) -> Double? {
        guard let entry = model.watchedHistoryEntry(videoID: video.id),
              video.duration > 0 else {
            return nil
        }
        return min(max(entry.lastPlaybackPosition / video.duration, 0), 1)
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = recent.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await client.videos(page: 1)
            guard !Task.isCancelled else { return }
            recent = Array(
                result.recordedPrograms
                    .filter { !model.isVideoDeleted(id: $0.id) }
                    .prefix(10)
            )
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }

        let mylistIDs = model.mylistVideoIDs
        if mylistIDs.isEmpty {
            mylist = []
        } else if let result = try? await client.videos(ids: mylistIDs) {
            guard !Task.isCancelled else { return }
            mylist = Array(
                result.recordedPrograms
                    .filter { !model.isVideoDeleted(id: $0.id) }
                    .prefix(4)
            )
        }

        let historyIDs = model.historyVideoIDs
        if historyIDs.isEmpty {
            history = []
        } else if let result = try? await client.videos(ids: historyIDs) {
            guard !Task.isCancelled else { return }
            history = Array(
                result.recordedPrograms
                    .filter { !model.isVideoDeleted(id: $0.id) }
                    .prefix(4)
            )
        }
    }
}

/// One horizontal row of the videos home screen.
private struct VideosHomeSection: View {
    let model: AppModel
    let title: String
    let programs: [RecordedProgram]
    let route: SectionRoute
    let moreIdentifier: String
    let itemPrefix: String
    let progress: ((RecordedProgram) -> Double?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                NavigationLink(value: route) {
                    Text("もっと見る")
                        .font(.subheadline)
                }
                .accessibilityIdentifier(moreIdentifier)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(programs) { video in
                        NavigationLink(value: SectionRoute.video(video)) {
                            VideoCard(
                                video: video,
                                thumbnailURL: model.client?.thumbnailURL(videoID: video.id),
                                progress: progress?(video)
                            )
                            .frame(width: 220)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("\(itemPrefix).\(video.id)")
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
