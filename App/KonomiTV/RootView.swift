import SwiftUI

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
        if isCompact {
            compactInterface
        } else {
            regularInterface
        }
    }

    // MARK: - Compact (iPhone, narrow windows)

    private var compactInterface: some View {
        TabView(selection: $model.section) {
            NavigationStack {
                LiveChannelsView(model: model)
            }
            .tabItem { tabLabel(for: .live) }
            .tag(AppSection.live)

            NavigationStack {
                VideosView(model: model)
            }
            .tabItem { tabLabel(for: .videos) }
            .tag(AppSection.videos)

            NavigationStack {
                SettingsView(model: model)
            }
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
                        .tag(section)
                        .accessibilityIdentifier("sidebar.\(section.rawValue)")
                }
            }
            .navigationTitle("KonomiTV")
            .accessibilityIdentifier("sidebar")
        } detail: {
            NavigationStack {
                sectionContent(model.section)
            }
            // A fresh stack per section, so screens pushed in one section do
            // not stay on top after switching to another.
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

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        switch section {
        case .live:
            LiveChannelsView(model: model)
        case .videos:
            VideosView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}
