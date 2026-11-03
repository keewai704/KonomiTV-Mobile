import Foundation

/// Builds the HLS playlist of a saved video from its stored segments.
///
/// The playlist is a finished VOD playlist (`#EXT-X-PLAYLIST-TYPE:VOD` +
/// `#EXT-X-ENDLIST`), so AVPlayer knows the duration up front and seeking works
/// without the server. Segment URIs are relative, which lets the loopback
/// server serve the playlist at `/offline/playlist.m3u8` and the segments at
/// `/offline/segments/<n>.ts`.
public enum OfflineHLSPlaylist {
    /// Directory (inside the saved video) the segments are written to.
    public static let segmentDirectoryName = "segments"

    /// `#EXT-X-TARGETDURATION`: the ceiling of the longest segment, at least 1.
    public static func targetDuration(for segments: [OfflineSegmentInfo]) -> Int {
        let maximum = segments.map(\.durationSeconds).max() ?? 0
        return max(Int(ceil(maximum)), 1)
    }

    /// Media playlist of a saved video.
    ///
    /// MPEG-TS needs no init segment; a fragmented MP4 save gets an
    /// `#EXT-X-MAP` line pointing at its stored init segment.
    public static func mediaPlaylist(
        for video: OfflineVideo,
        segmentPathPrefix: String = "\(segmentDirectoryName)/"
    ) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-TARGETDURATION:\(targetDuration(for: video.segments))",
        ]
        if video.container.requiresInitSegment, let initSegment = video.initSegmentFile, !initSegment.isEmpty {
            lines.append("#EXT-X-MAP:URI=\"\(initSegment)\"")
        }
        for segment in video.segments.sorted(by: { $0.sequence < $1.sequence }) {
            lines.append(String(format: "#EXTINF:%.3f,", segment.durationSeconds))
            lines.append("\(segmentPathPrefix)\(segment.sequence).\(video.container.fileExtension)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
