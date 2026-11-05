import SwiftUI

extension View {
    /// A search field under the title in the tab bar interface, and on the
    /// trailing side of the toolbar in the sidebar interface (large windows),
    /// where the HIG places it on iPad.
    func adaptiveSearchable(text: Binding<String>, prompt: String) -> some View {
        modifier(AdaptiveSearchable(text: text, prompt: prompt))
    }
}

private struct AdaptiveSearchable: ViewModifier {
    @Environment(\.windowLayout) private var windowLayout
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        content.searchable(
            text: $text,
            placement: windowLayout.usesSidebar
                ? .toolbar
                : .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
    }
}
