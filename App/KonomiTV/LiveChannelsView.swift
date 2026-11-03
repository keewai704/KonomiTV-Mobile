import SwiftUI
import UIKit
import KonomiKit

/// テレビ: live channel list with a broadcast type picker.
struct LiveChannelsView: View {
    let model: AppModel

    @State private var channels: LiveChannels?
    @State private var selectedType: ChannelType?
    @State private var errorMessage: String?

    var body: some View {
        content
            .navigationTitle("テレビ")
            .task { await load() }
    }

    // MARK: - Derived state

    private var availableTypes: [ChannelType] {
        guard let channels else { return [] }
        return ChannelType.allCases.filter { !channels.channels(for: $0).isEmpty }
    }

    private var activeType: ChannelType {
        selectedType ?? availableTypes.first ?? .gr
    }

    private var activeChannels: [LiveChannel] {
        channels?.channels(for: activeType) ?? []
    }

    private var typeSelection: Binding<ChannelType> {
        Binding(
            get: { activeType },
            set: { selectedType = $0 }
        )
    }

    // MARK: - Views

    @ViewBuilder
    private var content: some View {
        if let channels, !channels.isEmpty {
            channelList
        } else if channels != nil {
            ContentUnavailableView("チャンネルがありません", systemImage: "tv.slash")
        } else if let errorMessage {
            ContentUnavailableView {
                Label("チャンネルを取得できませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("再試行") {
                    Task { await load() }
                }
            }
        } else {
            ProgressView("読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var channelList: some View {
        VStack(spacing: 0) {
            Picker("チャンネル種別", selection: typeSelection) {
                ForEach(availableTypes, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("live.typePicker")

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(activeChannels) { channel in
                        NavigationLink(value: channel) {
                            ChannelCard(
                                channel: channel,
                                logoURL: model.client?.logoURL(channelID: channel.displayChannelID)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.channel.\(channel.displayChannelID)")
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .refreshable { await load() }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let client = model.client else {
            errorMessage = "サーバーが設定されていません。"
            return
        }

        errorMessage = nil

        do {
            let result = try await client.channels()
            guard !Task.isCancelled else { return }
            channels = result
            if let selectedType, result.channels(for: selectedType).isEmpty {
                self.selectedType = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = ErrorText.message(for: error)
        }
    }
}

/// One live channel card: logo, name, current program progress and next
/// program.
struct ChannelCard: View {
    let channel: LiveChannel
    let logoURL: URL?

    private var now: Date { Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let program = channel.programPresent {
                VStack(alignment: .leading, spacing: 6) {
                    Text(program.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ProgressView(value: program.progress(at: now))
                        .tint(.accentColor)

                    HStack(spacing: 6) {
                        Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
                        Spacer(minLength: 0)
                        Text(Formatters.percent(program.progress(at: now)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("番組情報がありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let following = channel.programFollowing {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("次")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Text(following.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            logo

            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text("チャンネル \(channel.channelNumber)")
                    if channel.isRadioChannel {
                        Label("ラジオ", systemImage: "radio")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var logo: some View {
        AsyncImage(url: logoURL) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                placeholderLogo
                    .opacity(phase.error == nil ? 0.4 : 1)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholderLogo: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.secondary.opacity(0.15))
            .overlay(
                Image(systemName: "tv")
                    .foregroundStyle(.secondary)
            )
    }
}
