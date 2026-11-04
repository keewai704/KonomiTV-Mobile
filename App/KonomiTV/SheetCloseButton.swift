import SwiftUI

/// Dismisses a sheet without saving. The HIG puts this button on the leading
/// edge of a sheet's toolbar; iOS 26 and later draw the system Close glyph.
struct SheetCloseButton: ToolbarContent {
    var accessibilityIdentifier = "sheet.close"
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Group {
                if #available(iOS 26.0, *) {
                    Button(role: .close, action: action)
                } else {
                    Button("閉じる", action: action)
                }
            }
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
