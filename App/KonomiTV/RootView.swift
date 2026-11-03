import SwiftUI
import KonomiKit

/// Chooses between the first run setup flow and the main interface, and
/// between a tab bar (compact widths) and a sidebar (regular widths).
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
        TabView(selection: $model.section) {
            sectionStack(.live)
                .tabItem { tabLabel(for: .live) }
                .tag(AppSection.live)

            sectionStack(.videos)
                .tabItem { tabLabel(for: .videos) }
                .tag(AppSection.videos)

            sectionStack(.settings)
                .tabItem { tabLabel(for: .settings) }
                .tag(AppSection.settings)
        }
    }

    private func tabLabel(for section: AppSection) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .accessibilityIdentifier("tab.\(section.rawValue)")
    }

    // MARK: - Regular (iPad, Split View, Stage Manager)

    private var regularInterface: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                ForEach(AppSection.allCases) { section in
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
    @ViewBuilder
    private func sectionStack(_ section: AppSection) -> some View {
        switch section {
        case .live:
            NavigationStack(path: $model.livePath) {
                LiveChannelsView(model: model)
                    .navigationDestination(for: LiveChannel.self) { channel in
                        LivePlayerView(model: model, channel: channel)
                    }
            }
        case .videos:
            NavigationStack(path: $model.videosPath) {
                VideosView(model: model)
                    .navigationDestination(for: RecordedProgram.self) { video in
                        VideoDetailView(model: model, video: video)
                    }
            }
        case .settings:
            NavigationStack {
                SettingsView(model: model)
            }
        }
    }
}

