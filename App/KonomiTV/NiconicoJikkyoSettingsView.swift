import SwiftUI
import AuthenticationServices
import UIKit
import Foundation
import KonomiKit

/// 設定 → ニコニコ実況: Niconico account linking and every comment preference
/// (views/Settings/Jikkyo.vue and components/Settings/CommentMuteSettings.vue).
struct NiconicoJikkyoSettingsView: View {
    let model: AppModel

    @State private var linkController = NiconicoLinkController()

    var body: some View {
        Form {
            accountSection
            postingSection
            appearanceSection
            muteSection
            keywordSection
            mutedUsersSection
        }
        .navigationTitle("ニコニコ実況")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("ニコニコアカウント") {
            if let user = model.user {
                if user.isNiconicoLinked {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("連携中のアカウント")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(user.niconicoUserName ?? "")
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("settings.niconico.name")
                    }

                    if user.niconicoUserPremium == true {
                        LabeledContent("プレミアム会員", value: "オン")
                    }

                    Button("連携を解除", role: .destructive) {
                        Task { await linkController.unlink(model: model) }
                    }
                    .disabled(linkController.isWorking)
                    .accessibilityIdentifier("settings.niconico.unlink")
                } else {
                    Button("連携する") {
                        Task { await linkController.link(model: model) }
                    }
                    .disabled(linkController.isWorking)
                    .accessibilityIdentifier("settings.niconico.link")
                }
            } else {
                Text("ニコニコアカウントと連携するにはログインが必要です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if linkController.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if let message = linkController.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.niconico.status")
            }
        }
    }

    // MARK: - Posting

    private var postingSection: some View {
        Section("コメント") {
            Toggle(
                "可能であればニコニコ実況にコメントする",
                isOn: boolBinding(\.preferPostingToNicolive)
            )
            .accessibilityIdentifier("settings.jikkyo.preferNicolive")
        }
    }

    private var appearanceSection: some View {
        Section("コメントの表示") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(
                    "コメントの速さ",
                    value: String(format: "%.1f倍", model.settings.commentSpeedRate)
                )
                Slider(
                    value: doubleBinding(\.commentSpeedRate),
                    in: 0.5...2,
                    step: 0.1
                )
            }
            .accessibilityIdentifier("settings.jikkyo.speed")

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(
                    "コメントの文字サイズ",
                    value: "\(Int(model.settings.commentFontSize))"
                )
                Slider(
                    value: doubleBinding(\.commentFontSize),
                    in: 20...60,
                    step: 1
                )
            }
            .accessibilityIdentifier("settings.jikkyo.fontSize")

            Toggle(
                "コメント送信後にコメント入力フォームを閉じる",
                isOn: boolBinding(\.closeCommentFormAfterSending)
            )
            .accessibilityIdentifier("settings.jikkyo.closeFormAfterSending")
        }
    }

    // MARK: - Mute

    private var muteSection: some View {
        Section("コメントのミュート設定") {
            Toggle(
                "露骨な表現を含むコメントをミュートする",
                isOn: boolBinding(\.muteVulgarComments)
            )
            .accessibilityIdentifier("settings.mute.vulgar")

            Toggle(
                "ネガティブな表現、差別的な表現、政治的に偏った表現を含むコメントをミュートする",
                isOn: boolBinding(\.muteAbusiveDiscriminatoryPrejudicedComments)
            )
            .accessibilityIdentifier("settings.mute.abusive")

            Toggle(
                "文字サイズが大きいコメントをミュートする",
                isOn: boolBinding(\.muteBigSizeComments)
            )
            .accessibilityIdentifier("settings.mute.bigSize")

            Toggle(
                "映像の上下に固定表示されるコメントをミュートする",
                isOn: boolBinding(\.muteFixedComments)
            )
            .accessibilityIdentifier("settings.mute.fixed")

            Toggle(
                "色付きのコメントをミュートする",
                isOn: boolBinding(\.muteColoredComments)
            )
            .accessibilityIdentifier("settings.mute.colored")

            Toggle(
                "8文字以上同じ文字が連続しているコメントをミュートする",
                isOn: boolBinding(\.muteConsecutiveSameCharactersComments)
            )
            .accessibilityIdentifier("settings.mute.consecutive")

            Toggle(
                "ミュート対象キーワードの英数字・記号を、大文字小文字や全角半角の違いを無視して判定する",
                isOn: boolBinding(\.muteCommentKeywordsNormalizeAlphanumericWidthCase)
            )
            .accessibilityIdentifier("settings.mute.normalize")
        }
    }

    private var keywordSection: some View {
        Section("ミュートするキーワード") {
            ForEach(
                Array(model.settings.mutedCommentKeywords.enumerated()),
                id: \.offset
            ) { index, keyword in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("ミュートするキーワード", text: keywordPatternBinding(index))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.mute.keyword.\(index)")

                    HStack(spacing: 12) {
                        Menu {
                            Picker("一致条件", selection: Binding(
                                get: { keyword.match },
                                set: { setKeywordMatch($0, at: index) }
                            )) {
                                ForEach(MutedCommentKeyword.MatchType.allCases, id: \.self) { match in
                                    Text(match.displayName).tag(match)
                                }
                            }
                        } label: {
                            Text(keyword.match.displayName)
                        }
                        .accessibilityIdentifier("settings.mute.match.\(index)")

                        Spacer(minLength: 0)

                        Button(role: .destructive) {
                            deleteKeyword(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityIdentifier("settings.mute.deleteKeyword.\(index)")
                        .accessibilityLabel("キーワードを削除")
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                addKeyword()
            } label: {
                Label("キーワードを追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.mute.addKeyword")
        }
    }

    private var mutedUsersSection: some View {
        Section("ミュート済みのニコニコユーザー ID") {
            ForEach(
                Array(model.settings.mutedNiconicoUserIDs.enumerated()),
                id: \.offset
            ) { index, _ in
                HStack(spacing: 12) {
                    TextField("ミュートするニコニコユーザー ID", text: userIDBinding(index))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.mute.user.\(index)")

                    Button(role: .destructive) {
                        deleteUserID(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityIdentifier("settings.mute.deleteUser.\(index)")
                    .accessibilityLabel("ユーザー ID を削除")
                }
            }

            Button {
                addUserID()
            } label: {
                Label("ユーザー ID を追加", systemImage: "plus")
            }
            .accessibilityIdentifier("settings.mute.addUser")
        }
    }

    // MARK: - Settings bindings

    private func boolBinding(
        _ keyPath: WritableKeyPath<ClientSettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.mutateSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func doubleBinding(
        _ keyPath: WritableKeyPath<ClientSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { newValue in
                model.mutateSettings { settings in
                    settings[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func keywordPatternBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard model.settings.mutedCommentKeywords.indices.contains(index) else {
                    return ""
                }
                return model.settings.mutedCommentKeywords[index].pattern
            },
            set: { newValue in
                model.mutateSettings { settings in
                    guard settings.mutedCommentKeywords.indices.contains(index) else { return }
                    settings.mutedCommentKeywords[index].pattern = newValue
                }
            }
        )
    }

    private func userIDBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard model.settings.mutedNiconicoUserIDs.indices.contains(index) else {
                    return ""
                }
                return model.settings.mutedNiconicoUserIDs[index]
            },
            set: { newValue in
                model.mutateSettings { settings in
                    guard settings.mutedNiconicoUserIDs.indices.contains(index) else { return }
                    settings.mutedNiconicoUserIDs[index] = newValue
                }
            }
        )
    }

    private func setKeywordMatch(_ match: MutedCommentKeyword.MatchType, at index: Int) {
        model.mutateSettings { settings in
            guard settings.mutedCommentKeywords.indices.contains(index) else { return }
            settings.mutedCommentKeywords[index].match = match
        }
    }

    private func addKeyword() {
        model.mutateSettings { settings in
            settings.mutedCommentKeywords.append(
                MutedCommentKeyword(match: .partial, pattern: "")
            )
        }
    }

    private func deleteKeyword(at index: Int) {
        model.mutateSettings { settings in
            guard settings.mutedCommentKeywords.indices.contains(index) else { return }
            settings.mutedCommentKeywords.remove(at: index)
        }
    }

    private func addUserID() {
        model.mutateSettings { settings in
            settings.mutedNiconicoUserIDs.append("")
        }
    }

    private func deleteUserID(at index: Int) {
        model.mutateSettings { settings in
            guard settings.mutedNiconicoUserIDs.indices.contains(index) else { return }
            settings.mutedNiconicoUserIDs.remove(at: index)
        }
    }
}

// MARK: - Keyword match names

extension MutedCommentKeyword.MatchType {
    /// The web client's match type labels.
    var displayName: String {
        switch self {
        case .partial: return "部分一致"
        case .forward: return "前方一致"
        case .backward: return "後方一致"
        case .exact: return "完全一致"
        case .regex: return "正規表現"
        }
    }
}

// MARK: - Niconico OAuth

/// Runs the Niconico account link flow (views/Settings/Jikkyo.vue).
///
/// The authorization URL is requested with `Origin: konomitv://`, so the
/// server's OAuth callback redirects back to the app's URL scheme. On iOS the
/// system `ASWebAuthenticationSession` sheet shows Niconico; UI tests pass
/// `-UITestingDisableASWebAuth` and load the same URL with URLSession instead.
@MainActor
@Observable
final class NiconicoLinkController {
    private(set) var isWorking = false
    private(set) var message: String?

    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private var presenter = WebAuthenticationPresenter()

    func link(model: AppModel) async {
        guard !isWorking else { return }
        guard let client = model.client, model.token != nil else {
            message = "連携をはじめるには、KonomiTV アカウントにログインしてください。"
            return
        }

        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            let auth = try await client.niconicoAuthURL(origin: "konomitv://")
            guard let url = auth.authorizationURL else {
                message = "ニコニコアカウントとの連携に失敗しました。"
                return
            }

            if model.disablesASWebAuthentication {
                let failure = await loadAuthorizationURLWithURLSession(url)
                guard failure == nil else {
                    message = failure
                    return
                }
                await model.refreshUser()
                message = model.user?.isNiconicoLinked == true
                    ? "ニコニコアカウントと連携しました。"
                    : "ニコニコアカウントとの連携に失敗しました。"
                return
            }

            let callback = try await present(url)
            await handleCallback(callback, model: model)
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // The user closed the sheet; no message.
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    func unlink(model: AppModel) async {
        guard !isWorking, let client = model.client else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }

        do {
            try await client.unlinkNiconico()
            await model.refreshUser()
            message = "ニコニコアカウントとの連携を解除しました。"
        } catch {
            message = ErrorText.message(for: error)
        }
    }

    // MARK: - ASWebAuthenticationSession

    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "konomitv"
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: NiconicoLinkError.missingCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = presenter
            self.session = session
            if !session.start() {
                continuation.resume(throwing: NiconicoLinkError.cannotStart)
            }
        }
    }

    private func handleCallback(_ url: URL, model: AppModel) async {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            message = "ニコニコアカウントとの連携に失敗しました。"
            return
        }

        var components = URLComponents()
        components.percentEncodedQuery = fragment
        let items = components.queryItems ?? []
        let status = Int(items.first { $0.name == "status" }?.value ?? "") ?? 0
        let detail = items.first { $0.name == "detail" }?.value ?? ""

        guard status == 200 else {
            message = Self.failureMessage(status: status, detail: detail)
            return
        }

        await model.refreshUser()
        message = "ニコニコアカウントと連携しました。"
    }

    // MARK: - UI-test fallback

    /// Loads the authorization URL with URLSession. The mock (and the real
    /// server) redirects through `/api/niconico/callback`, which links the
    /// account and answers 200. Returns a failure message, or nil on success.
    private func loadAuthorizationURLWithURLSession(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return "ニコニコアカウントとの連携に失敗しました。"
            }
            return nil
        } catch {
            return ErrorText.message(for: error)
        }
    }

    // MARK: - Messages (views/Settings/Jikkyo.vue)

    private static func failureMessage(status: Int, detail: String) -> String {
        if detail.hasPrefix("Authorization was denied (access_denied)") {
            return "ニコニコアカウントとの連携がキャンセルされました。"
        }
        if detail.hasPrefix("Failed to get access token (HTTP Error ") {
            let error = detail.replacingOccurrences(of: "Failed to get access token ", with: "")
            return "アクセストークンの取得に失敗しました。\(error)"
        }
        if detail.hasPrefix("Failed to get access token (Connection Timeout)") {
            return "アクセストークンの取得に失敗しました。ニコニコで障害が発生している可能性があります。"
        }
        if detail.hasPrefix("Failed to get user information (HTTP Error ") {
            let error = detail.replacingOccurrences(of: "Failed to get user information ", with: "")
            return "ニコニコアカウントのユーザー情報の取得に失敗しました。\(error)"
        }
        if detail.hasPrefix("Failed to get user information (Connection Timeout)") {
            return "ニコニコアカウントのユーザー情報の取得に失敗しました。ニコニコで障害が発生している可能性があります。"
        }
        return "ニコニコアカウントとの連携に失敗しました。(\(detail))"
    }
}

private enum NiconicoLinkError: LocalizedError {
    case missingCallback
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .missingCallback:
            return "ニコニコアカウントとの連携に失敗しました。"
        case .cannotStart:
            return "ニコニコアカウントとの連携を開始できませんでした。"
        }
    }
}

/// Presentation anchor of the system authentication sheet.
@MainActor
final class WebAuthenticationPresenter: NSObject,
    @preconcurrency ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
