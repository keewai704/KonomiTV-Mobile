import SwiftUI
import UIKit
import KonomiKit

/// One recorded program card: thumbnail, title, date and duration.
struct VideoCard: View {
    let video: RecordedProgram
    let thumbnailURL: URL?
    /// Resume position (0...1) shown as a bar on watch history items.
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail

            Text(video.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Text(Formatters.dateTime(video.startTime))
                Text("・")
                Text(Formatters.duration(video.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let channel = video.channel {
                Text(channel.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var thumbnail: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                AsyncImage(url: thumbnailURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.black.opacity(0.5))
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
