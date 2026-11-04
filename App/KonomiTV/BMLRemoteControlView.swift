import SwiftUI

/// データ放送のリモコン.
///
/// The buttons are the web client's remote (Panel/Remocon.vue): the cursor
/// keys with 決定, データ (d) and 戻る, the four colour keys and the number
/// keys 1–12. A key is only enabled while the BML content accepts it
/// (web-bml's used-key-list); `d` is always enabled because the data button is
/// not part of that list.
struct BMLRemoteControlView: View {
    let controller: DataBroadcastingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("リモコン")
                    .font(.subheadline.weight(.semibold))
                if controller.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }

            directionalPad
            controlKeys
            numberKeys
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bml.remote")
    }

    // MARK: - Sections

    /// 方向キー and 決定 in a cross, so the grouping is the arrow layout.
    private var directionalPad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 52, height: 40)
                keyButton("up", systemImage: "chevron.up")
                    .frame(width: 52, height: 40)
                Color.clear.frame(width: 52, height: 40)
            }
            GridRow {
                keyButton("left", systemImage: "chevron.left")
                    .frame(width: 52, height: 40)
                keyButton("enter", label: "決定")
                    .frame(width: 52, height: 40)
                keyButton("right", systemImage: "chevron.right")
                    .frame(width: 52, height: 40)
            }
            GridRow {
                Color.clear.frame(width: 52, height: 40)
                keyButton("down", systemImage: "chevron.down")
                    .frame(width: 52, height: 40)
                Color.clear.frame(width: 52, height: 40)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// データ (d), 戻る and the four colour keys.
    private var controlKeys: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                keyButton("d", label: "データ")
                keyButton("back", label: "戻る")
            }
            HStack(spacing: 4) {
                keyButton("blue", label: "青", tint: .blue, isProminent: true)
                keyButton("red", label: "赤", tint: .red, isProminent: true)
                keyButton("green", label: "緑", tint: .green, isProminent: true)
                keyButton("yellow", label: "黄", tint: .yellow, isProminent: true)
            }
        }
    }

    /// Numbers 1–12 (the web client's remote number keys).
    private var numberKeys: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
            spacing: 4
        ) {
            ForEach(1...12, id: \.self) { number in
                keyButton(String(number), label: String(number))
                    .frame(minHeight: 36)
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private func keyButton(
        _ name: String,
        label: String? = nil,
        systemImage: String? = nil,
        tint: Color? = nil,
        isProminent: Bool = false
    ) -> some View {
        Group {
            if isProminent {
                Button {
                    controller.sendKey(name)
                } label: {
                    buttonLabel(label, systemImage)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    controller.sendKey(name)
                } label: {
                    buttonLabel(label, systemImage)
                }
                .buttonStyle(.bordered)
            }
        }
        .tint(tint)
        .disabled(!controller.enabledKeys.contains(name))
        .accessibilityIdentifier("bml.key.\(name)")
        .accessibilityLabel(label ?? name)
    }

    private func buttonLabel(_ label: String?, _ systemImage: String?) -> some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
            } else {
                Text(label ?? "")
            }
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 34)
    }
}
