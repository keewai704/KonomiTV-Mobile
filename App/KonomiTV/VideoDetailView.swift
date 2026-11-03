import SwiftUI
import AVFoundation
import KonomiKit

/// A recorded program, with the HLS player above (or beside) the details.
struct VideoDetailView: View {
    let model: AppModel
    let video: RecordedProgram

    @AppStorage(PreferenceKeys.videoQuality) private var qualityRaw: String = StreamQuality.p1080.rawValue
    @State private var detail: RecordedProgram?
    @State private var player: AVPlayer?
    @State private var sessionID = String(UUID().uuidString.prefix(8)).lowercased()

    private var current: RecordedProgram { detail ?? video }

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
        .task { await startPlaybackIfNeeded() }
        .task { await loadDetail() }
        .task { await keepAliveLoop() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Views

    @ViewBuilder
    private var playerArea: some View {
        if let player {
            PlayerView(player: player)
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

    // MARK: - Playback

    private func startPlaybackIfNeeded() async {
        guard player == nil, let client = model.client else { return }

        let url = client.videoPlaylistURL(
            videoID: video.id,
            quality: quality,
            sessionID: sessionID
        )
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = true
        player = newPlayer
        newPlayer.play()
    }

    private func loadDetail() async {
        guard let client = model.client else { return }
        guard let loaded = try? await client.video(id: video.id) else { return }
        detail = loaded
    }

    /// KonomiTV stops a recording session that stops sending keep-alives.
    private func keepAliveLoop() async {
        guard let client = model.client else { return }
        while !Task.isCancelled {
            try? await client.keepAlive(
                videoID: video.id,
                quality: quality,
                sessionID: sessionID
            )
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
