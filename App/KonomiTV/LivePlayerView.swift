import SwiftUI
import KonomiKit

/// テレビ: live playback. The raw MPEG-TS stream is re-packaged into HLS by
/// LiveStreamSession and played from a loopback HTTP server.
///
/// Playback itself is owned by the app wide PlaybackController, so picture in
/// picture and background playback survive navigating away from this screen.
struct LivePlayerView: View {
    let model: AppModel
    let channel: LiveChannel

    @AppStorage(PreferenceKeys.liveQuality) private var qualityRaw: String = StreamQuality.p1080.rawValue

    private var quality: StreamQuality {
        StreamQuality(rawValue: qualityRaw) ?? .p1080
    }

    private var playbackItem: PlaybackItem { .live(channel) }

    private var playback: PlaybackController { model.playback }

    var body: some View {
        AdaptivePlayerLayout(
            player: { playerArea },
            info: { info }
        )
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { startPlayback() }
        .onAppear { playback.viewAppeared(for: playbackItem) }
        .onDisappear { playback.viewDisappeared(for: playbackItem) }
    }

    // MARK: - Views

    @ViewBuilder
    private var playerArea: some View {
        if playback.item == playbackItem, playback.isPlayerAttached {
            PlayerView(playback: playback)
        } else if playback.item == playbackItem, let message = playback.liveErrorMessage {
            errorArea(message)
        } else {
            loadingArea
        }
    }

    private func errorArea(_ message: String) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Button("再試行") {
                    playback.retry()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }

    private var loadingArea: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("ライブ配信を準備しています…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(channel.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("チャンネル \(channel.channelNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let program = channel.programPresent {
                VStack(alignment: .leading, spacing: 8) {
                    Text(program.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    ProgressView(value: program.progress(at: Date()))
                        .tint(.accentColor)

                    HStack(spacing: 8) {
                        Text(Formatters.timeRange(start: program.startTime, end: program.endTime))
                        Spacer(minLength: 0)
                        Text(Formatters.percent(program.progress(at: Date())))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !program.description.isEmpty {
                        Text(program.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("番組情報がありません")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let following = channel.programFollowing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("次の番組")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(following.title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Formatters.timeRange(start: following.startTime, end: following.endTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Session

    private func startPlayback() {
        guard let client = model.client else { return }
        playback.play(playbackItem, client: client, quality: quality)
    }
}

