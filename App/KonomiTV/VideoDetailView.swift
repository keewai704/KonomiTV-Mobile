import SwiftUI
import KonomiKit

/// A recorded program, with the HLS player above (or beside) the details.
///
/// Playback itself is owned by the app wide PlaybackController, so picture in
/// picture and background playback survive navigating away from this screen.
struct VideoDetailView: View {
    let model: AppModel
    let video: RecordedProgram

    @AppStorage(PreferenceKeys.videoQuality) private var qualityRaw: String = StreamQuality.p1080.rawValue
    @State private var detail: RecordedProgram?

    private var current: RecordedProgram { detail ?? video }

    private var playbackItem: PlaybackItem { .video(video) }

    private var quality: StreamQuality {
        StreamQuality(rawValue: qualityRaw)?.videoSafe ?? .p1080
    }

    var body: some View {
        AdaptivePlayerLayout(
            player: { playerArea },
            info: { info }
        )
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { startPlayback() }
        .task { await loadDetail() }
        .onAppear { model.playback.viewAppeared(for: playbackItem) }
        .onDisappear { model.playback.viewDisappeared(for: playbackItem) }
    }

    // MARK: - Views

    @ViewBuilder
    private var playerArea: some View {
        if model.playback.item == playbackItem, model.playback.isPlayerAttached {
            PlayerView(playback: model.playback)
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(current.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("video.detail.title")

            HStack(spacing: 8) {
                if let channel = current.channel {
                    Text(channel.name)
                }
                Text(Formatters.dateTime(current.startTime))
                Text("・")
                Text(Formatters.duration(current.duration))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if !current.genres.isEmpty {
                Text(current.genres.map { "\($0.major)／\($0.middle)" }.joined(separator: "・"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !current.description.isEmpty {
                Text(current.description)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Loading

    private func startPlayback() {
        guard let client = model.client else { return }
        model.playback.play(playbackItem, client: client, quality: quality)
    }

    private func loadDetail() async {
        guard let client = model.client else { return }
        guard let loaded = try? await client.video(id: video.id) else { return }
        detail = loaded
    }
}

