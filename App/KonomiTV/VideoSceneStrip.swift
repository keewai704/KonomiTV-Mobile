import Foundation
import SwiftUI
import UIKit
import KonomiKit

/// Horizontally scrolling scene thumbnails for a recorded program.
///
/// The strip uses the seek-bar tiled thumbnail sheet
/// (`GET /api/videos/{id}/thumbnail/tiled`) and crops one tile per scene with
/// Core Graphics; tapping a scene seeks the shared player there.
struct VideoSceneStrip: View {
    let playback: PlaybackController
    let videoID: Int
    let tile: ThumbnailTileInfo
    let client: APIClient

    @State private var sheet: CGImage?
    @State private var didFail = false

    private var columnCount: Int { max(tile.columnCount, 1) }
    private var rowCount: Int {
        tile.rowCount > 0
            ? tile.rowCount
            : max(Int(ceil(Double(tile.totalTiles) / Double(columnCount))), 1)
    }
    private var sceneCount: Int {
        let count = tile.totalTiles > 0
            ? tile.totalTiles
            : columnCount * rowCount
        return min(max(count, 0), 120)
    }

    var body: some View {
        if sceneCount > 0, tile.intervalSec > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(0..<sceneCount, id: \.self) { index in
                        sceneButton(index: index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.black)
            .accessibilityIdentifier("video.scenes")
            .task(id: videoID) {
                await loadSheet()
            }
        } else {
            EmptyView()
        }
    }

    private func sceneButton(index: Int) -> some View {
        let time = Double(index) * tile.intervalSec
        let timeText = Self.timeLabel(time)

        return Button {
            playback.seek(to: time)
        } label: {
            VStack(spacing: 4) {
                sceneImage(index: index)
                    .frame(width: 160, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12))
                    )
                    .overlay {
                        if didFail || sheet == nil {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        }
                    }

                Text(timeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("video.scene.\(index)")
        .accessibilityLabel(timeText)
        .accessibilityValue(String(Int(time)))
    }

    @ViewBuilder
    private func sceneImage(index: Int) -> some View {
        if let sheet, let cropped = crop(sheet, index: index) {
            Image(decorative: cropped, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Color.clear
        }
    }

    private func crop(_ image: CGImage, index: Int) -> CGImage? {
        let column = index % columnCount
        let row = index / columnCount
        let tileWidth = tile.tileWidth > 0
            ? tile.tileWidth
            : image.width / columnCount
        let tileHeight = tile.tileHeight > 0
            ? tile.tileHeight
            : image.height / rowCount
        guard tileWidth > 0, tileHeight > 0 else { return nil }

        let rect = CGRect(
            x: column * tileWidth,
            y: row * tileHeight,
            width: tileWidth,
            height: tileHeight
        )
        guard rect.maxX <= image.width, rect.maxY <= image.height else { return nil }
        return image.cropping(to: rect)
    }

    private func loadSheet() async {
        guard sheet == nil, !didFail else { return }
        do {
            let (data, response) = try await URLSession.shared.data(
                from: client.tiledThumbnailURL(videoID: videoID)
            )
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let uiImage = UIImage(data: data),
                  let cgImage = uiImage.cgImage else {
                didFail = true
                return
            }
            sheet = cgImage
        } catch {
            didFail = true
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}
