import SwiftUI
import UIKit
import KonomiKit

/// ビデオ: recorded program grid with paging and debounced search.
struct VideosView: View {
    let model: AppModel

    @State private var items: [RecordedProgram] = []
    @State private var total = 0
    @State private var page = 0
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var appliedQuery = ""

    var body: some View {
        content
            .navigationTitle("ビデオ")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "ビデオを検索"
            )
            .task(id: query) {
                await handleQueryChange()
            }
    }

    // MARK: - Views

    @ViewBuilder
    private var content: some View {
        if !items.isEmpty {
            grid
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
                    Task { await reload() }
                }
            }
        } else if !appliedQuery.isEmpty {
            ContentUnavailableView.search(text: appliedQuery)
        } else {
            ContentUnavailableView("ビデオがありません", systemImage: "film.stack")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(items) { video in
                    NavigationLink(value: video) {
                        VideoCard(
                            video: video,
                            thumbnailURL: model.client?.thumbnailURL(videoID: video.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("videos.item.\(video.id)")
                    .onAppear { loadMoreIfNeeded(after: video) }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if isLoadingMore {
                ProgressView()
                    .padding(.vertical, 20)
            }
        }
        .accessibilityIdentifier("videos.grid")
        .refreshable { await reload() }
    }

    // MARK: - Search

    private func handleQueryChange() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Debounce typing so the API is not queried on every keystroke.
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }

        if trimmed == appliedQuery && !items.isEmpty { return }
        appliedQuery = trimmed
        await reload()
    }

    // MARK: - Loading

    private func fetch(page: Int, client: APIClient) async throws -> RecordedPrograms {
        if appliedQuery.isEmpty {
            return try await client.videos(page: page)
        }
        return try await client.searchVideos(query: appliedQuery, page: page)
    }

    private func reload() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        isLoading = items.isEmpty
        errorMessage = nil
        defer { isLoading = false }

        do {
            let result = try await fetch(page: 1, client: client)
            guard !Task.isCancelled else { return }
            items = result.recordedPrograms
            total = result.total
            page = 1
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func loadMoreIfNeeded(after video: RecordedProgram) {
        guard video.id == items.last?.id else { return }
        guard !isLoading, !isLoadingMore, items.count < total else { return }
        guard let client = model.client else { return }

        isLoadingMore = true
        let requestedQuery = appliedQuery
        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = page + 1
                let result = try await fetch(page: nextPage, client: client)
                // Drop a page that belongs to a search the user has replaced.
                guard !Task.isCancelled, requestedQuery == appliedQuery else { return }
                let known = Set(items.map(\.id))
                items.append(contentsOf: result.recordedPrograms.filter { !known.contains($0.id) })
                total = result.total
                page = nextPage
            } catch {
                // Paging failures keep the already loaded items; the user can
                // pull to refresh to retry.
            }
        }
    }
}

/// One recorded program card: thumbnail, title, date and duration.
struct VideoCard: View {
    let video: RecordedProgram
    let thumbnailURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(Formatters.dateTime(video.startTime))
                Text("・")
                Text(Formatters.duration(video.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let channel = video.channel {
                Text(channel.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var thumbnail: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
