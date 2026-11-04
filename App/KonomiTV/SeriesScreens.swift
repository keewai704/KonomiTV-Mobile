import Foundation
import SwiftUI
import UIKit
import KonomiKit

// MARK: - Card

/// One series in a list: title, genres and the number of recorded episodes.
struct SeriesCard: View {
    let series: Series

    private var episodeCount: Int { series.allRecordedPrograms.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(series.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !genresText.isEmpty {
                        Text(genresText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text("\(episodeCount) 本の録画番組")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !series.description.isEmpty {
                Text(series.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var genresText: String {
        series.genres
            .map { "\($0.major)／\($0.middle)" }
            .joined(separator: "・")
    }
}

// MARK: - List

/// シリーズ: every series of the server with search, sort order and paging
/// (`GET /api/series` and `GET /api/series/search`).
struct SeriesListScreen: View {
    let model: AppModel

    @State private var items: [Series] = []
    @State private var total = 0
    @State private var page = 0
    @State private var order: VideoListOrder = .desc
    @State private var query = ""
    @State private var appliedQuery = ""
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("シリーズ")
            .adaptiveSearchable(text: $query, prompt: "シリーズを検索")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                }
            }
            .task(id: query) {
                await handleQueryChange()
            }
            .onChange(of: order) { _, _ in
                Task { await reload() }
            }
    }

    private var sortMenu: some View {
        Menu {
            Picker("並び順", selection: $order) {
                Text("新しい順").tag(VideoListOrder.desc)
                Text("古い順").tag(VideoListOrder.asc)
            }
        } label: {
            Label(order == .desc ? "新しい順" : "古い順", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("series.sort")
    }

    @ViewBuilder
    private var content: some View {
        if !items.isEmpty {
            grid
        } else if isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("シリーズを取得できませんでした", systemImage: "wifi.exclamationmark")
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
            ContentUnavailableView("シリーズがありません", systemImage: "rectangle.stack")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(items) { series in
                    NavigationLink(value: SectionRoute.series(series.id)) {
                        SeriesCard(series: series)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("series.item.\(series.id)")
                    .onAppear { loadMoreIfNeeded(after: series) }
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)

            if isLoadingMore {
                ProgressView()
                    .padding(.vertical, 20)
            }
        }
        .accessibilityIdentifier("series.list")
        .refreshable { await reload() }
    }

    // MARK: - Search / paging

    private func handleQueryChange() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }
        if trimmed == appliedQuery, !items.isEmpty { return }
        appliedQuery = trimmed
        await reload()
    }

    private func fetch(page: Int, client: APIClient) async throws -> SeriesList {
        if appliedQuery.isEmpty {
            return try await client.seriesList(page: page, order: order)
        }
        return try await client.searchSeries(query: appliedQuery, page: page, order: order)
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
            items = result.seriesList
            total = result.total
            page = 1
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }

    private func loadMoreIfNeeded(after series: Series) {
        guard series.id == items.last?.id else { return }
        guard !isLoading, !isLoadingMore, items.count < total else { return }
        guard let client = model.client else { return }

        isLoadingMore = true
        let requestedQuery = appliedQuery
        Task {
            defer { isLoadingMore = false }
            do {
                let nextPage = page + 1
                let result = try await fetch(page: nextPage, client: client)
                guard !Task.isCancelled, requestedQuery == appliedQuery else { return }
                let known = Set(items.map(\.id))
                items.append(contentsOf: result.seriesList.filter { !known.contains($0.id) })
                total = result.total
                page = nextPage
            } catch {
                // Paging failures keep the loaded items; pull to refresh retries.
            }
        }
    }
}

// MARK: - Detail

/// シリーズ詳細: the series information with its recorded episodes, grouped by
/// broadcast period, and the My List toggle (the web client's series panel).
struct SeriesDetailScreen: View {
    let model: AppModel
    let seriesID: Int

    @State private var series: Series?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var isInMylist: Bool { model.isInMylist(seriesID: seriesID) }

    var body: some View {
        content
            .navigationTitle(series?.title ?? "シリーズ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.toggleMylist(seriesID: seriesID)
                    } label: {
                        Image(systemName: isInMylist ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityIdentifier("series.mylist")
                    .accessibilityLabel(isInMylist ? "マイリストから削除" : "マイリストに追加")
                }
            }
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let series {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(series)

                    ForEach(Array(series.broadcastPeriods.enumerated()), id: \.offset) { _, period in
                        broadcastPeriod(period)
                    }
                }
                .padding(.vertical, 16)
            }
            .accessibilityIdentifier("series.detail")
        } else if isLoading {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("シリーズを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                if let errorMessage {
                    Text(errorMessage)
                }
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        }
    }

    private func header(_ series: Series) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(series.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("series.detail.title")

            if !series.genres.isEmpty {
                Text(
                    series.genres
                        .map { "\($0.major)／\($0.middle)" }
                        .joined(separator: "・")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text("\(series.allRecordedPrograms.count) 本の録画番組")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !series.description.isEmpty {
                Text(series.description)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func broadcastPeriod(_ period: SeriesBroadcastPeriod) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(period.channel?.name ?? "チャンネル不明")
                    .font(.headline)
                if !period.startDate.isEmpty || !period.endDate.isEmpty {
                    Text("\(period.startDate) 〜 \(period.endDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(period.recordedPrograms) { episode in
                    NavigationLink(value: SectionRoute.video(episode)) {
                        VideoCard(
                            video: episode,
                            thumbnailURL: model.client?.thumbnailURL(videoID: episode.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("series.episode.\(episode.id)")
                }
            }
            .padding(.horizontal)
        }
    }

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            isLoading = false
            return
        }
        isLoading = series == nil
        errorMessage = nil
        defer { isLoading = false }

        do {
            let loaded = try await client.series(id: seriesID)
            guard !Task.isCancelled else { return }
            series = loaded
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

// MARK: - My List strip

/// The series part of マイリスト: a horizontal strip of the saved series.
struct MylistSeriesStrip: View {
    let model: AppModel
    let seriesList: [Series]
    let onRemove: (Series) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("シリーズ")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(seriesList) { series in
                        NavigationLink(value: SectionRoute.series(series.id)) {
                            SeriesCard(series: series)
                                .frame(width: 280)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mylist.series.\(series.id)")
                        .contextMenu {
                            Button("マイリストから削除", role: .destructive) {
                                onRemove(series)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 12)
        .accessibilityIdentifier("mylist.seriesStrip")
    }
}
