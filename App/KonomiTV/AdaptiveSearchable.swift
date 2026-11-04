import SwiftUI

extension View {
    /// A search field under the title on iPhone, and on the trailing side of
    /// the toolbar on iPad, where the HIG places it.
    func adaptiveSearchable(text: Binding<String>, prompt: String) -> some View {
        modifier(AdaptiveSearchable(text: text, prompt: prompt))
    }
}

private struct AdaptiveSearchable: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        content.searchable(
            text: $text,
            placement: sizeClass == .regular
                ? .toolbar
                : .navigationBarDrawer(displayMode: .always),
            prompt: prompt
        )
    }
}
