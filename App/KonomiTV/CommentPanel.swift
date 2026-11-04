import SwiftUI
import UIKit
import KonomiKit

/// One row of a comment list. Live comments and past log comments both become
/// this, so the panel and the sessions share the row shape.
struct CommentRow: Identifiable, Hashable, Sendable {
    let id: Int
    let danmaku: CommentDanmaku
    /// `HH:mm:ss` of the comment (28 hour clock when the setting is on).
    let displayTime: String

    var text: String { danmaku.text }
    var authorID: String { danmaku.authorID }
    var isOwnComment: Bool { danmaku.isOwnComment }
}

/// Scrolling comment list with the row context menu, auto-scroll to the newest
/// comment and a jump-to-latest button while the user is reading older ones.
struct CommentListPanel: View {
    var title: String?
    let comments: [CommentRow]
    let statusMessage: String?
    let height: CGFloat
    let onMuteUser: (String) -> Void

    @State private var isScrolledUp = false

    private let bottomID = "comment.list.bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                    if !comments.isEmpty {
                        Text("\(comments.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("comment.status")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comments.indices, id: \.self) { index in
                            rowView(comments[index], index: index)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            // Dragging downwards means the user is going back
                            // through older comments.
                            if value.translation.height > 12 {
                                isScrolledUp = true
                            }
                        }
                )
                .onChange(of: comments.count) { _, _ in
                    guard !isScrolledUp else { return }
                    scrollToBottom(proxy)
                }
                .onAppear {
                    scrollToBottom(proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isScrolledUp {
                        Button {
                            isScrolledUp = false
                            scrollToBottom(proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(8)
                        .accessibilityIdentifier("comment.jumpToLatest")
                        .accessibilityLabel("最新のコメントへ")
                    }
                }
            }
            .frame(height: height)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomID, anchor: .bottom)
    }

    private func rowView(_ row: CommentRow, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.displayTime)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(row.text)
                .font(.footnote)
                .foregroundStyle(row.isOwnComment ? Color.accentColor : Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("comment.row.\(index)")
        .contextMenu {
            Button {
                onMuteUser(row.authorID)
            } label: {
                Label("ミュートするユーザーに追加", systemImage: "person.crop.circle.badge.xmark")
            }

            Button {
                UIPasteboard.general.string = row.text
            } label: {
                Label("コピー", systemImage: "doc.on.doc")
            }
        }
    }
}

/// Live comment form (web: the DPlayer comment box). The field and the three
/// menus send the same Niconico colour / position / size commands as the web
/// client.
struct CommentPostingForm: View {
    let isEnabled: Bool
    let successfulPostCount: Int
    let closeAfterSending: Bool
    /// Incremented by the M shortcut to focus the field.
    let focusRequest: Int
    let onSend: (String, String, CommentDanmaku.Position, CommentDanmaku.Size) -> Bool

    @State private var text = ""
    @State private var color = CommentCommands.defaultColor
    @State private var position: CommentDanmaku.Position = .scroll
    @State private var size: CommentDanmaku.Size = .medium
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("コメント", text: $text)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit(send)
                .accessibilityIdentifier("comment.input")

            colorMenu
            positionMenu
            sizeMenu

            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!isEnabled || trimmedText.isEmpty)
            .accessibilityIdentifier("comment.send")
            .accessibilityLabel("コメントを送信")
        }
        .onChange(of: focusRequest) { _, _ in
            isFocused = true
        }
        .onChange(of: successfulPostCount) { _, _ in
            text = ""
            if closeAfterSending {
                // Closing the form on iOS means dismissing the keyboard.
                isFocused = false
            }
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard isEnabled, !trimmedText.isEmpty else { return }
        _ = onSend(trimmedText, color, position, size)
    }

    // MARK: - Menus

    private var colorMenu: some View {
        Menu {
            Picker("コメントの色", selection: $color) {
                ForEach(JikkyoPostComment.palette, id: \.self) { hex in
                    Text(Self.colorName(hex)).tag(hex)
                }
            }
        } label: {
            Circle()
                .fill(Color(uiColor: UIColor(commentHex: color)))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
        }
        .accessibilityIdentifier("comment.color")
        .accessibilityLabel("コメントの色")
    }

    private var positionMenu: some View {
        Menu {
            Picker("コメントの位置", selection: $position) {
                ForEach(CommentDanmaku.Position.allCases, id: \.self) { item in
                    Text(Self.positionName(item)).tag(item)
                }
            }
        } label: {
            Image(systemName: Self.positionIcon(position))
                .frame(width: 20, height: 20)
        }
        .accessibilityIdentifier("comment.position")
        .accessibilityLabel("コメントの位置")
    }

    private var sizeMenu: some View {
        Menu {
            Picker("コメントのサイズ", selection: $size) {
                ForEach(CommentDanmaku.Size.allCases, id: \.self) { item in
                    Text(Self.sizeName(item)).tag(item)
                }
            }
        } label: {
            Image(systemName: Self.sizeIcon(size))
                .frame(width: 20, height: 20)
        }
        .accessibilityIdentifier("comment.size")
        .accessibilityLabel("コメントのサイズ")
    }

    // MARK: - Names (DPlayer's Japanese translations)

    private static func colorName(_ hex: String) -> String {
        switch hex.uppercased() {
        case "#FFEAEA": return "白"
        case "#F02840": return "赤"
        case "#FD7E80": return "ピンク"
        case "#FDA708": return "オレンジ"
        case "#FFE133": return "黄色"
        case "#64DD17": return "緑"
        case "#00D4F5": return "水色"
        case "#4763FF": return "青"
        default: return hex
        }
    }

    private static func positionName(_ position: CommentDanmaku.Position) -> String {
        switch position {
        case .top: return "上固定"
        case .scroll: return "スクロール"
        case .bottom: return "下固定"
        }
    }

    private static func positionIcon(_ position: CommentDanmaku.Position) -> String {
        switch position {
        case .top: return "arrow.up.to.line"
        case .scroll: return "arrow.left.to.line"
        case .bottom: return "arrow.down.to.line"
        }
    }

    private static func sizeName(_ size: CommentDanmaku.Size) -> String {
        switch size {
        case .big: return "大きめ"
        case .medium: return "標準"
        case .small: return "小さめ"
        }
    }

    private static func sizeIcon(_ size: CommentDanmaku.Size) -> String {
        switch size {
        case .big: return "textformat.size.larger"
        case .medium: return "textformat.size"
        case .small: return "textformat.size.smaller"
        }
    }
}
