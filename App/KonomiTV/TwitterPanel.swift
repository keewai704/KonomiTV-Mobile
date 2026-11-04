import SwiftUI
import KonomiKit

/// The watch screen's Twitter / Bluesky tab.
///
/// Mirrors the web client's Panel/Twitter.vue: an account picker, the post
/// target of linked accounts, the composer with hashtags and session captures,
/// and the Search / Timeline / Capture sub tabs.
struct TwitterPanelView: View {
    let model: AppModel
    @Bindable var session: TwitterSession
    let context: TwitterPanelContext

    @State private var tab: TwitterPanelTab = .capture
    @State private var didSetInitialTab = false
    @State private var previewImage: PreviewImage?
    @FocusState private var focusedField: ComposerField?

    private enum ComposerField: Hashable {
        case text
        case hashtag
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accountRow

            if session.accountItems.isEmpty {
                noAccountNotice
            } else {
                composer
                subTabPicker

                switch tab {
                case .search:
                    TwitterFeedView(
                        model: model,
                        session: session,
                        kind: .search,
                        query: $session.searchQuery,
                        previewImage: $previewImage
                    )
                case .timeline:
                    TwitterFeedView(
                        model: model,
                        session: session,
                        kind: .timeline,
                        query: .constant(""),
                        previewImage: $previewImage
                    )
                case .capture:
                    captureGrid
                }
            }
        }
        // Without .contain the container's identifier replaces the sub tabs'.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("twitter.panel")
        .task {
            await session.load()
        }
        .onAppear {
            session.updateContext(
                channelName: context.channelName,
                programTitle: context.programTitle,
                programID: context.programID
            )
            if !didSetInitialTab {
                didSetInitialTab = true
                tab = model.settings.twitterActiveTab
            }
            session.startKeepAlive()
        }
        .onChange(of: context) { _, newValue in
            session.updateContext(
                channelName: newValue.channelName,
                programTitle: newValue.programTitle,
                programID: newValue.programID
            )
        }
        .onChange(of: tab) { _, newValue in
            model.mutateSettings { settings in
                settings.twitterActiveTab = newValue
            }
        }
        .onDisappear {
            session.stopKeepAlive()
        }
        .sheet(item: $previewImage) { image in
            TweetImagePreview(image: image)
        }
        .toolbar {
            // The body is multi-line, so return adds a line; on compact
            // widths the keyboard also covers the send button.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
                    .accessibilityIdentifier("keyboard.done")
            }
        }
    }

    // MARK: - Accounts

    private var noAccountNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.user == nil
                ? "Twitter / Bluesky を連携するには、KonomiTV アカウントにログインしてください。"
                : "Twitter / Bluesky アカウントが連携されていません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("twitter.noAccount")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var accountRow: some View {
        HStack(spacing: 8) {
            Menu {
                if session.accountItems.isEmpty {
                    Button("連携中のアカウントはありません") {}
                        .disabled(true)
                } else {
                    ForEach(session.accountItems) { item in
                        Toggle(accountMenuTitle(item), isOn: Binding(
                            get: { item.account == session.selectedItem?.account },
                            set: { if $0 { session.select(item) } }
                        ))
                        .accessibilityIdentifier("twitter.account.option.\(item.id)")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let url = session.selectedItem?.iconURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                    }
                    Text(session.selectedItem?.displayName ?? "未連携")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let item = session.selectedItem {
                        Text("@\(item.screenName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("twitter.account")
            .accessibilityLabel("投稿するアカウント")

            if session.selectedItem?.bluesky != nil, session.selectedItem?.twitter != nil {
                Button {
                    session.cyclePostTarget()
                } label: {
                    Text(session.postTarget.isPostToTwitter
                        ? (session.postTarget.isPostToBluesky ? "Twitter / Bluesky" : "Twitter")
                        : "Bluesky")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("twitter.account.target")
                .accessibilityLabel("送信先")
                .accessibilityValue(session.postTarget.isPostToTwitter
                    ? (session.postTarget.isPostToBluesky ? "両方" : "Twitter")
                    : "Bluesky")
            }

            Spacer(minLength: 0)

            if session.isRefreshingAccounts {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func accountMenuTitle(_ item: TwitterAccountItem) -> String {
        switch item {
        case .twitter(let account):
            return "\(account.name) (@\(account.screenName))"
        case .bluesky(let account):
            return "\(account.name) (@\(account.handle))"
        case .linked(let link):
            return "\(link.twitterAccount.name) / \(link.blueskyAccount.name)"
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = session.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(session.noticeIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("twitter.status")
            }

            ZStack(alignment: .topLeading) {
                if session.text.isEmpty {
                    Text(session.postTarget.isPostToTwitter ? "ツイート" : "ポスト")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $session.text)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .text)
                    .accessibilityIdentifier("twitter.compose.text")
                    .accessibilityLabel("ツイート本文")
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            hashtagRow

            if !capturedSelection.isEmpty {
                attachmentStrip
            }

            HStack(spacing: 10) {
                Text("\(session.remainingCharacters)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remainingColor)
                    .accessibilityIdentifier("twitter.compose.count")
                    .accessibilityLabel("残りの文字数")

                Label("\(session.selectedCaptureCount)/4", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("添付したキャプチャ")

                Spacer(minLength: 0)

                Button {
                    session.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!session.canSend)
                .accessibilityIdentifier("twitter.compose.send")
                .accessibilityLabel(session.postTarget.isPostToTwitter ? "ツイート" : "ポスト")
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var remainingColor: Color {
        if session.remainingCharacters <= 0 {
            return .red
        }
        return session.remainingCharacters <= 20 ? .orange : .secondary
    }

    private var hashtagRow: some View {
        HStack(spacing: 8) {
            TextField("#ハッシュタグ", text: $session.hashtagField)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focusedField, equals: .hashtag)
                .onSubmit(normalizeHashtag)
                .accessibilityIdentifier("twitter.compose.hashtag")
                .accessibilityLabel("ハッシュタグ")

            Menu {
                Button {
                    session.saveCurrentHashtags()
                } label: {
                    Label("現在のハッシュタグを保存", systemImage: "plus")
                }
                .accessibilityIdentifier("twitter.compose.saved.save")

                if !model.settings.savedTwitterHashtags.isEmpty {
                    Divider()
                    ForEach(Array(model.settings.savedTwitterHashtags.enumerated()), id: \.offset) { entry in
                        Button {
                            session.applySavedHashtag(entry.element)
                        } label: {
                            Text(entry.element)
                        }
                        .accessibilityIdentifier("twitter.compose.saved.\(entry.offset)")
                    }
                    Divider()
                    ForEach(Array(model.settings.savedTwitterHashtags.enumerated()), id: \.offset) { entry in
                        Button(role: .destructive) {
                            session.removeSavedHashtag(entry.element)
                        } label: {
                            Text("\(entry.element) を削除")
                        }
                        .accessibilityIdentifier("twitter.compose.saved.delete.\(entry.offset)")
                    }
                }
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("twitter.compose.saved")
            .accessibilityLabel("保存したハッシュタグ")
        }
    }

    private func normalizeHashtag() {
        session.hashtagField = session.formattedHashtag
    }

    /// Captures of this session that are selected for attaching.
    private var capturedSelection: [ProducedCapture] {
        session.selectedCaptureIndices.sorted().compactMap { index in
            let captures = session.captures
            return captures.indices.contains(index) ? captures[index] : nil
        }
    }

    private var attachmentStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(capturedSelection.enumerated()), id: \.offset) { entry in
                if let image = UIImage(data: entry.element.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .accessibilityIdentifier("twitter.compose.attachments")
    }

    // MARK: - Sub tabs

    private var subTabPicker: some View {
        HStack(spacing: 2) {
            subTabButton(.search, identifier: "twitter.tab.search")
            subTabButton(.timeline, identifier: "twitter.tab.timeline")
            subTabButton(.capture, identifier: "twitter.tab.capture")
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func subTabButton(_ item: TwitterPanelTab, identifier: String) -> some View {
        Button {
            tab = item
        } label: {
            Text(item.displayName)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    tab == item ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(tab == item ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Captures

    private var captureGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                spacing: 6
            ) {
                ForEach(Array(session.captures.enumerated()), id: \.offset) { entry in
                    captureCell(index: entry.offset, capture: entry.element)
                }
            }
            .padding(.vertical, 2)

            if session.captures.isEmpty {
                Text("キャプチャはまだありません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
                    .accessibilityIdentifier("twitter.capture.empty")
            }
        }
        .frame(maxHeight: 320)
    }

    private func captureCell(index: Int, capture: ProducedCapture) -> some View {
        Button {
            session.toggleCapture(index)
        } label: {
            ZStack(alignment: .topTrailing) {
                if let image = UIImage(data: capture.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 76)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Color.secondary.opacity(0.15)
                        .frame(height: 76)
                }

                if session.isCaptureSelected(index) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(
                        session.isCaptureSelected(index) ? Color.accentColor : Color.clear,
                        lineWidth: 2
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("twitter.capture.\(index)")
        .accessibilityLabel(capture.filename)
        .accessibilityValue(session.isCaptureSelected(index) ? "選択中" : "未選択")
    }
}

/// Watch context the panel needs (nil channel name for recorded video).
struct TwitterPanelContext: Equatable {
    var channelName: String?
    var programTitle: String
    var programID: String?
}

/// An image opened from a tweet row.
struct PreviewImage: Identifiable {
    let id: String
    let url: URL
}

/// Full screen image viewer of a tweet image.
struct TweetImagePreview: View {
    let image: PreviewImage

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: image.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.white.opacity(0.7))
                    default:
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .accessibilityIdentifier("twitter.imageViewer")
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetCloseButton { dismiss() }
            }
        }
    }
}
