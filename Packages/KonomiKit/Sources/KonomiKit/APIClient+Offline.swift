import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Offline save streams

extension APIClient {

    /// Whether the server has the offline save stream (KonomiTV 0.15+).
    ///
    /// KonomiTV v0.14.1 has no `offline-stream` route at all, so it answers 404.
    /// The probe deliberately asks for an invalid quality and an unknown video:
    /// the 0.15+ route validates the path and answers 422, which proves the
    /// route exists without starting an encoder or downloading anything. The
    /// request carries no token because the save stream itself is anonymous.
    public func offlineStreamsAvailable() async throws -> Bool {
        let request = makeRequest(
            path: ["streams", "video", "0", "invalid", "offline-stream"],
            authorized: false
        )
        do {
            _ = try await sendRaw(request)
            return true
        } catch let error as APIError {
            if error.statusCode == 404 {
                return false
            }
            // Any other HTTP answer (422 "unknown video", 405, ...) means the
            // route is there; only a missing route is a 404.
            if error.statusCode != nil {
                return true
            }
            throw error
        }
    }

    /// `GET /api/streams/video/{video_id}/{quality}/offline-stream`.
    ///
    /// The response is KonomiTV's custom binary stream; feed it to
    /// `OfflineStreamParser`.
    public func offlineStreamURL(videoID: Int, apiQuality: String) -> URL {
        Endpoints.videoOfflineStream(
            baseURL: baseURL,
            videoID: videoID,
            apiQuality: apiQuality
        )
    }
}
