import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Captures API

extension APIClient {

    /// Whether the server has the captures library (v0.15+).
    ///
    /// KonomiTV v0.14.1 only has POST /api/captures (upload); every other
    /// captures endpoint answers 404. The list endpoint is used as the probe
    /// because it is anonymous and cheap (limit=1). Uploads are not probed
    /// because they are handled differently by the old server (204 without a
    /// body) and must keep working.
    public func capturesLibraryAvailable() async throws -> Bool {
        let request = makeRequest(
            path: ["captures"],
            query: [URLQueryItem(name: "limit", value: "1")]
        )
        do {
            _ = try await sendRaw(request)
            return true
        } catch let error as APIError where error.statusCode == 404 {
            return false
        }
    }

    // MARK: List

    /// One page of captures (GET /api/captures).
    ///
    /// - Parameters:
    ///   - order: CapturedAtDesc by default. BroadcastAtDesc/Asc drop captures
    ///     without broadcast metadata on the server.
    ///   - filter: The filter menu conditions.
    ///   - cursor: next_cursor from the previous page.
    ///   - limit: 1...200 (server default 100).
    ///   - date: YYYY-MM-DD (JST) to fetch a single day of the timeline.
    ///   - dayStartHour: Where a day starts (4 for the 28 hour clock).
    public func captures(
        filter: CaptureFilters = CaptureFilters(),
        order: CaptureSortOrder = .capturedAtDesc,
        cursor: String? = nil,
        limit: Int = 100,
        date: String? = nil,
        dayStartHour: Int? = nil
    ) async throws -> Captures {
        let url = Endpoints.captures(
            baseURL: baseURL,
            filter: filter,
            order: order,
            cursor: cursor,
            limit: limit,
            date: date,
            dayStartHour: dayStartHour
        )
        return try await perform(authorizedRequest(url), as: Captures.self)
    }

    /// Daily capture counts for the timeline (GET /api/captures/sections).
    public func captureSections(
        filter: CaptureFilters = CaptureFilters(),
        axis: CaptureTimelineAxis = .capturedAt,
        dayStartHour: Int = 0
    ) async throws -> CaptureSections {
        let url = Endpoints.captureSections(
            baseURL: baseURL,
            filter: filter,
            axis: axis,
            dayStartHour: dayStartHour
        )
        return try await perform(authorizedRequest(url), as: CaptureSections.self)
    }

    /// Channels that have at least one available capture
    /// (GET /api/captures/channels).
    public func captureChannels() async throws -> [CaptureChannel] {
        try await perform(
            makeRequest(path: ["captures", "channels"]),
            as: [CaptureChannel].self
        )
    }

    /// Broadcast episodes that have captures, as albums
    /// (GET /api/captures/programs).
    ///
    /// - Parameters:
    ///   - query: Space separated keywords, ANDed, matched against the program
    ///     title and the channel name.
    ///   - hasRecordedProgram: Only episodes with / without a recorded program.
    public func capturePrograms(
        cursor: String? = nil,
        limit: Int = 60,
        query: String? = nil,
        hasRecordedProgram: Bool? = nil,
        order: CaptureProgramSortOrder = .broadcastAtDesc
    ) async throws -> CapturePrograms {
        let url = Endpoints.capturePrograms(
            baseURL: baseURL,
            cursor: cursor,
            limit: limit,
            query: query,
            hasRecordedProgram: hasRecordedProgram,
            order: order
        )
        return try await perform(authorizedRequest(url), as: CapturePrograms.self)
    }

    /// One album (GET /api/captures/programs/{id}). 404 when the episode has no
    /// available captures.
    public func captureProgram(id: Int) async throws -> CaptureProgramAlbum {
        try await perform(
            makeRequest(path: ["captures", "programs", String(id)]),
            as: CaptureProgramAlbum.self
        )
    }

    // MARK: Detail / delete

    /// One capture with its episode and stored files
    /// (GET /api/captures/{id}).
    public func capture(id: Int) async throws -> CaptureDetail {
        try await perform(
            makeRequest(path: ["captures", String(id)]),
            as: CaptureDetail.self
        )
    }

    /// Deletes captures and their files (DELETE /api/captures, admin only).
    ///
    /// The server returns which IDs it could delete and which it could not.
    public func deleteCaptures(ids: [Int]) async throws -> CaptureDeleteResult {
        guard !ids.isEmpty else {
            return CaptureDeleteResult()
        }
        let body = try encodeJSON(CaptureIDsBody(captureIDs: ids))
        let request = makeRequest(
            path: ["captures"],
            method: "DELETE",
            body: body,
            contentType: "application/json"
        )
        return try await perform(request, as: CaptureDeleteResult.self)
    }

    // MARK: Favorites / tags

    /// Adds captures to the viewer's favourites (POST /api/captures/favorites).
    /// Requires a login.
    public func addCaptureFavorites(ids: [Int]) async throws {
        guard !ids.isEmpty else { return }
        let request = makeRequest(
            path: ["captures", "favorites"],
            method: "POST",
            body: try encodeJSON(CaptureIDsBody(captureIDs: ids)),
            contentType: "application/json"
        )
        _ = try await sendRaw(request)
    }

    /// Removes captures from the viewer's favourites
    /// (DELETE /api/captures/favorites). Requires a login.
    public func removeCaptureFavorites(ids: [Int]) async throws {
        guard !ids.isEmpty else { return }
        let request = makeRequest(
            path: ["captures", "favorites"],
            method: "DELETE",
            body: try encodeJSON(CaptureIDsBody(captureIDs: ids)),
            contentType: "application/json"
        )
        _ = try await sendRaw(request)
    }

    /// The viewer's tags, sorted by name (GET /api/captures/tags). Requires a
    /// login.
    public func captureTags() async throws -> [CaptureTag] {
        try await perform(makeRequest(path: ["captures", "tags"]), as: [CaptureTag].self)
    }

    /// Creates a tag (POST /api/captures/tags). Requires a login. The server
    /// trims the name and rejects duplicates with 422.
    public func createCaptureTag(name: String) async throws -> CaptureTag {
        let request = makeRequest(
            path: ["captures", "tags"],
            method: "POST",
            body: try encodeJSON(CaptureTagBody(name: name)),
            contentType: "application/json"
        )
        return try await perform(request, as: CaptureTag.self)
    }

    /// Renames a tag (PUT /api/captures/tags/{id}). Requires a login.
    public func renameCaptureTag(id: Int, name: String) async throws -> CaptureTag {
        let request = makeRequest(
            path: ["captures", "tags", String(id)],
            method: "PUT",
            body: try encodeJSON(CaptureTagBody(name: name)),
            contentType: "application/json"
        )
        return try await perform(request, as: CaptureTag.self)
    }

    /// Deletes a tag (DELETE /api/captures/tags/{id}, 204). The captures
    /// themselves stay. Requires a login.
    public func deleteCaptureTag(id: Int) async throws {
        _ = try await sendRaw(
            makeRequest(path: ["captures", "tags", String(id)], method: "DELETE")
        )
    }

    /// Attaches a tag to captures (POST /api/captures/tags/{id}/items).
    /// Requires a login.
    public func addCaptureTagItems(tagID: Int, captureIDs: [Int]) async throws {
        guard !captureIDs.isEmpty else { return }
        let request = makeRequest(
            path: ["captures", "tags", String(tagID), "items"],
            method: "POST",
            body: try encodeJSON(CaptureIDsBody(captureIDs: captureIDs)),
            contentType: "application/json"
        )
        _ = try await sendRaw(request)
    }

    /// Detaches a tag from captures (DELETE /api/captures/tags/{id}/items).
    /// Requires a login.
    public func removeCaptureTagItems(tagID: Int, captureIDs: [Int]) async throws {
        guard !captureIDs.isEmpty else { return }
        let request = makeRequest(
            path: ["captures", "tags", String(tagID), "items"],
            method: "DELETE",
            body: try encodeJSON(CaptureIDsBody(captureIDs: captureIDs)),
            contentType: "application/json"
        )
        _ = try await sendRaw(request)
    }

    // MARK: Upload

    /// Uploads one capture image (POST /api/captures).
    ///
    /// The server expects a multipart/form-data body with one file part named
    /// "image" whose filename ends in .jpg/.jpeg/.png (the extension is checked,
    /// not only the content). An optional "file_modified_at" field (UNIX
    /// milliseconds) carries the original file's modification time so a local
    /// file's capture date is preserved.
    ///
    /// The current server answers 201 with the stored Capture (an existing
    /// capture with identical content is returned instead of saving a copy).
    /// KonomiTV v0.14.1 answers 204 without a body, so the result is nil there.
    ///
    /// Uploads are allowed while logged out. An expired token is ignored by the
    /// server rather than losing the capture.
    public func uploadCapture(
        image: Data,
        filename: String,
        contentType: String = "image/jpeg",
        fileModifiedAt: Date? = nil
    ) async throws -> Capture? {
        var form = MultipartFormData()
        form.addFile(
            name: "image",
            filename: filename,
            contentType: contentType,
            data: image
        )
        if let fileModifiedAt {
            let milliseconds = Int64((fileModifiedAt.timeIntervalSince1970 * 1000).rounded())
            form.addField(name: "file_modified_at", value: String(milliseconds))
        }
        var request = makeRequest(
            path: ["captures"],
            method: "POST",
            body: form.encoded(),
            contentType: contentType
        )
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (data, _) = try await sendRaw(request)
        guard !data.isEmpty else {
            return nil
        }
        do {
            return try JSONCoding.makeDecoder().decode(Capture.self, from: data)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // MARK: URLs

    /// Image URL of a captured image (GET /api/captures/{id}/image?hash=...).
    ///
    /// Pass the capture's file_hash; the server 404s without a matching hash.
    public func captureImageURL(id: Int, fileHash: String) -> URL {
        Endpoints.captureImage(baseURL: baseURL, id: id, hash: fileHash)
    }

    /// Convenience for a Capture.
    public func captureImageURL(for capture: Capture) -> URL {
        captureImageURL(id: capture.id, fileHash: capture.fileHash)
    }

    // MARK: Helpers

    private struct CaptureIDsBody: Encodable {
        var captureIDs: [Int]

        private enum CodingKeys: String, CodingKey {
            case captureIDs = "capture_ids"
        }
    }

    private struct CaptureTagBody: Encodable {
        var name: String
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONCoding.encode(value)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// A GET request for a URL built by Endpoints, with the same headers as
    /// makeRequest (Accept + optional bearer token).
    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
