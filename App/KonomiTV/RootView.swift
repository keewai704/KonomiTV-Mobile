import SwiftUI
import KonomiKit

/// Chooses between the first run setup flow and the main interface, and
/// between a tab bar plus マイページ hub (compact widths) and a sidebar
/// (regular widths).
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if model.isConfigured {
                mainInterface
            } else {
                SetupView(model: model)
            }
        }
        .task {
            await model.restoreSession()
        }
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    @ViewBuilder
    private var mainInterface: some View {
        Group {
            if isCompact {
                compactInterface
            } else {
                regularInterface
            }
        }
        .overlay(alignment: .topLeading) {
            playbackStatus
        }
    }

    /// Invisible status strings for the UI tests: background playback, the
    /// playback position and picture-in-picture state are readable from any
    /// screen.
    private var playbackStatus: some View {
        let playback = model.playback
        return VStack(spacing: 0) {
            statusText(playback.state, identifier: "playback.state")
            statusText(String(playback.positionSeconds), identifier: "playback.position")
            statusText(
                playback.isPictureInPictureActive ? "active" : "inactive",
                identifier: "playback.pip"
            )
            statusText(String(playback.pictureInPictureStartCount), identifier: "playback.pipStarts")
            statusText(
                playback.isPictureInPictureSupported ? "true" : "false",
                identifier: "playback.pipSupported"
            )
            statusText(playback.liveStatus, identifier: "live.status")
            statusText(String(playback.liveViewerCount), identifier: "live.viewerCount")
            statusText(String(playback.comments.drawnCount), identifier: "comments.drawnCount")
            statusText(String(playback.captions.renderedCount), identifier: "captions.renderedCount")
            statusText(
                playback.captions.isVisible && !playback.captions.isPictureInPictureActive
                    ? "true"
                    : "false",
                identifier: "captions.visible"
            )
            statusText(String(playback.capture.producedImageCount), identifier: "capture.count")
            statusText(playback.capture.lastFilename ?? "", identifier: "capture.lastFilename")
        }
        .font(.system(size: 1))
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    private func statusText(_ value: String, identifier: String) -> some View {
        Text(value)
            .accessibilityLabel(value)
            .accessibilityIdentifier(identifier)
    }

    // MARK: - Compact (iPhone, narrow windows)

    private var compactInterface: some View {
        TabView(selection: compactTabSelection) {
            sectionStack(.live)
                .tabItem { tabLabel(for: .live) }
                .tag(CompactTab.live)

            sectionStack(.videos)
                .tabItem { tabLabel(for: .videos) }
                .tag(CompactTab.videos)

            mypageStack
                .tabItem { tabLabel(for: .mypage) }
                .tag(CompactTab.mypage)
        }
    }

    /// Keeps the sidebar selection in sync with the tab bar, so switching
    /// between compact and regular widths (rotation, Split View) stays on the
    /// same section.
    private var compactTabSelection: Binding<CompactTab> {
        Binding(
            get: { model.compactTab },
            set: { newValue in
                model.compactTab = newValue
                switch newValue {
                case .live:
                    model.section = .live
                case .videos:
                    model.section = .videos
                case .mypage:
                    break
                }
            }
        )
    }

    private func tabLabel(for tab: CompactTab) -> some View {
        Label(tab.title, systemImage: tab.systemImage)
            .accessibilityIdentifier("tab.\(tab.rawValue)")
    }

    // MARK: - Regular (iPad, Split View, Stage Manager)

    private var regularInterface: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                ForEach(model.visibleSections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        // One element per row, so the identifier is not also
                        // attached to the (non-hittable) icon image.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("sidebar.\(section.rawValue)")
                        .tag(section)
                }
            }
            .navigationTitle("KonomiTV")
            .accessibilityIdentifier("sidebar")
        } detail: {
            sectionStack(model.section)
                // A fresh stack per section, so screens pushed in one section
                // do not stay on top after switching to another.
                .id(model.section)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarSelection: Binding<AppSection?> {
        Binding(
            get: { model.section },
            set: { newValue in
                if let newValue {
                    model.section = newValue
                }
            }
        )
    }

    // MARK: - Per section navigation stack

    /// Each section owns its navigation path on `AppModel`, so picture in
    /// picture restore can push the screen that owns the playback.
    private func sectionStack(_ section: AppSection) -> some View {
        NavigationStack(path: path(for: section)) {
            root(for: section)
                .navigationDestination(for: SectionRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    /// The compact マイページ tab: a hub that pushes the sections the tab bar
    /// has no room for.
    private var mypageStack: some View {
        NavigationStack(path: $model.mypagePath) {
            MyPageView(model: model)
                .navigationDestination(for: SectionRoute.self) { route in
                    destination(for: route)
                }
        }
    }

    private func path(for section: AppSection) -> Binding<[SectionRoute]> {
        switch section {
        case .live: return $model.livePath
        case .timetable: return $model.timetablePath
        case .videos: return $model.videosPath
        case .mylist: return $model.mylistPath
        case .history: return $model.historyPath
        case .captures: return $model.capturesPath
        case .settings: return $model.settingsPath
        }
    }

    @ViewBuilder
    private func root(for section: AppSection) -> some View {
        switch section {
        case .live:
            LiveChannelsView(model: model)
        case .timetable:
            TimeTableScreen(model: model)
        case .videos:
            VideosHomeView(model: model)
        case .mylist:
            MyListScreen(model: model)
        case .history:
            WatchedHistoryScreen(model: model)
        case .captures:
            CapturesLibraryScreen(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    @ViewBuilder
    private func destination(for route: SectionRoute) -> some View {
        switch route {
        case .live(let channel):
            LivePlayerView(model: model, channel: channel)
        case .video(let video):
            VideoDetailView(model: model, video: video)
        case .videoList:
            VideoListView(model: model)
        case .timetable:
            TimeTableScreen(model: model)
        case .mylist:
            MyListScreen(model: model)
        case .history:
            WatchedHistoryScreen(model: model)
        case .captures:
            CapturesLibraryScreen(model: model)
        case .captureProgram(let id):
            CaptureProgramScreen(model: model, programID: id)
        case .settings:
            SettingsView(model: model)
        case .pinnedChannels:
            PinnedChannelsView(model: model)
        }
    }
}
