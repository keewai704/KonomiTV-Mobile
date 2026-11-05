import SwiftUI

/// The interface follows the size and the aspect ratio of the window in points,
/// never the kind of device: the same window gets the same interface on an
/// iPhone and an iPad (Split View, Slide Over and Stage Manager windows
/// included). An iPhone turned sideways gets the player fullscreen because its
/// window is wide and low, not because it is an iPhone.
struct WindowLayout: Equatable, Sendable {
    /// The shape of the window: the navigation and the player follow it.
    enum Shape: Equatable, Sendable {
        /// Large: both sides are at least `largeMinimumShortSide` (an iPad
        /// full screen in either orientation, an iPad mini, a 2/3 Split View).
        /// Gets the sidebar, and the player beside its information when the
        /// space it measures is wider than tall.
        case large
        /// Landscape: shorter than that and wider than tall (an iPhone turned
        /// sideways, a low Stage Manager window). Gets the tab bar, and the
        /// player is always fullscreen.
        case landscape
        /// Portrait: everything else (an iPhone held upright, a narrow Split
        /// View). Gets the tab bar, and the player above its information.
        case portrait
    }

    /// Shortest side (width or height) of a window that gets the sidebar.
    static let largeMinimumShortSide: CGFloat = 700

    /// The whole window, safe areas included. Zero until it is measured.
    var size: CGSize = .zero

    var isMeasured: Bool { size.width > 0 && size.height > 0 }

    /// Applies a measured window size.
    ///
    /// A `GeometryReader` reports a zero size while the window is being
    /// replaced (rotation, Split View resizing, Stage Manager, the switch
    /// between the tab bar and the sidebar). Taking that value would flip
    /// `isMeasured` back to false, and `RootView` would drop the whole
    /// interface for its placeholder, player screen and playback included, so
    /// the last real size is kept instead.
    mutating func update(size newSize: CGSize) {
        guard newSize.width >= 1, newSize.height >= 1 else { return }
        size = newSize
    }

    /// Width divided by height (above 1 is wider than tall). Zero until it is
    /// measured.
    var aspectRatio: CGFloat {
        guard isMeasured else { return 0 }
        return size.width / size.height
    }

    /// The shape of the window, from its size and its aspect ratio. A window
    /// that is not measured yet counts as portrait, so the first frame gets the
    /// tab bar interface.
    var shape: Shape {
        guard isMeasured else { return .portrait }
        if min(size.width, size.height) >= Self.largeMinimumShortSide {
            return .large
        }
        return size.width > size.height ? .landscape : .portrait
    }

    /// Sidebar and split view; otherwise the tab bar.
    var usesSidebar: Bool { shape == .large }

    /// The tab bar interface and the compact variants of the screens.
    var isCompact: Bool { !usesSidebar }

    /// A wide, low window (an iPhone turned sideways, a low Stage Manager
    /// window): the player is always fullscreen there, and its screen has no
    /// button to leave fullscreen.
    var forcesFullscreenPlayer: Bool {
        isMeasured && shape == .landscape
    }
}

private struct WindowLayoutKey: EnvironmentKey {
    static let defaultValue = WindowLayout()
}

extension EnvironmentValues {
    /// The layout of the window the view is in (set by `RootView`).
    var windowLayout: WindowLayout {
        get { self[WindowLayoutKey.self] }
        set { self[WindowLayoutKey.self] = newValue }
    }
}

extension View {
    /// Measures the window (this view should fill it) into `layout`.
    ///
    /// `onUpdate` runs with the measured layout as soon as a real size is
    /// known, *before* the view tree is rebuilt with it: the navigation has to
    /// move its screens between the tab bar and the sidebar before the stacks of
    /// the interface that goes away are torn down (a torn down stack writes an
    /// empty path back, which would drop the screen).
    func measuringWindow(
        into layout: Binding<WindowLayout>,
        onUpdate: ((WindowLayout) -> Void)? = nil
    ) -> some View {
        background {
            GeometryReader { proxy in
                let size = CGSize(
                    width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                )
                Color.clear
                    .onAppear {
                        layout.wrappedValue.update(size: size)
                        onUpdate?(layout.wrappedValue)
                    }
                    .onChange(of: size) { _, newValue in
                        layout.wrappedValue.update(size: newValue)
                        onUpdate?(layout.wrappedValue)
                    }
            }
        }
    }
}
