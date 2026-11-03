import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Recording reservations API

/// KonomiTV's recording endpoints (EDCB backend only).
///
/// The three routers are mirrored one to one:
/// - ReservationsRouter: `/api/recording/reservations`
/// - ReservationConditionsRouter: `/api/recording/conditions`
/// - RecordingPresetsRouter: `/api/recording/presets`
///
/// Every endpoint answers 422 with
/// "This API is only available when the backend is EDCB" on a Mirakurun
/// backend, so callers should check `VersionInfo.backend` first.
extension APIClient {

    // MARK: - Reservations

    /// All recording reservations, sorted by program start time on the server.
    public func reservations() async throws -> Reservations {
        try await perform(
            makeRequest(path: ["recording", "reservations"]),
            as: Reservations.self
        )
    }

    /// One reservation including its full record settings.
    public func reservation(id: Int) async throws -> Reservation {
        try await perform(
            makeRequest(path: ["recording", "reservations", String(id)]),
            as: Reservation.self
        )
    }

    /// Adds a reservation for a program (`POST /api/recording/reservations`).
    ///
    /// The server answers 201 without a body (the new reservation ID is decided
    /// by EDCB), so the reservation list has to be reloaded afterwards.
    /// - Parameter program: Needed only when the program is not in the server's
    ///   database yet (an EIT[p/f] program); it lets the server build the
    ///   reservation without EPG data.
    public func addReservation(
        programID: String,
        recordSettings: RecordSettings,
        program: ReservationAddProgram? = nil
    ) async throws {
        let request = try jsonRequest(
            path: ["recording", "reservations"],
            method: "POST",
            body: ReservationAddRequest(
                programID: programID,
                recordSettings: recordSettings,
                program: program
            )
        )
        _ = try await sendRaw(request)
    }

    /// Replaces the record settings of a reservation
    /// (`PUT /api/recording/reservations/{id}`).
    public func updateReservation(
        id: Int,
        recordSettings: RecordSettings
    ) async throws -> Reservation {
        let request = try jsonRequest(
            path: ["recording", "reservations", String(id)],
            method: "PUT",
            body: ReservationUpdateRequest(recordSettings: recordSettings)
        )
        return try await perform(request, as: Reservation.self)
    }

    /// Deletes a reservation (`DELETE /api/recording/reservations/{id}`, 204).
    public func deleteReservation(id: Int) async throws {
        let request = makeRequest(
            path: ["recording", "reservations", String(id)],
            method: "DELETE"
        )
        _ = try await sendRaw(request)
    }

    // MARK: - Keyword conditions (EPG 自動予約)

    /// All keyword recording conditions.
    public func reservationConditions() async throws -> ReservationConditions {
        try await perform(
            makeRequest(path: ["recording", "conditions"]),
            as: ReservationConditions.self
        )
    }

    /// One keyword condition.
    public func reservationCondition(id: Int) async throws -> ReservationCondition {
        try await perform(
            makeRequest(path: ["recording", "conditions", String(id)]),
            as: ReservationCondition.self
        )
    }

    /// Registers a keyword condition (`POST /api/recording/conditions`, 201).
    public func addReservationCondition(
        programSearchCondition: ProgramSearchCondition,
        recordSettings: RecordSettings
    ) async throws {
        let request = try jsonRequest(
            path: ["recording", "conditions"],
            method: "POST",
            body: ReservationConditionRequest(
                programSearchCondition: programSearchCondition,
                recordSettings: recordSettings
            )
        )
        _ = try await sendRaw(request)
    }

    /// Replaces a keyword condition (`PUT /api/recording/conditions/{id}`).
    public func updateReservationCondition(
        id: Int,
        programSearchCondition: ProgramSearchCondition,
        recordSettings: RecordSettings
    ) async throws -> ReservationCondition {
        let request = try jsonRequest(
            path: ["recording", "conditions", String(id)],
            method: "PUT",
            body: ReservationConditionRequest(
                programSearchCondition: programSearchCondition,
                recordSettings: recordSettings
            )
        )
        return try await perform(request, as: ReservationCondition.self)
    }

    /// Deletes a keyword condition (`DELETE /api/recording/conditions/{id}`, 204).
    public func deleteReservationCondition(id: Int) async throws {
        let request = makeRequest(
            path: ["recording", "conditions", String(id)],
            method: "DELETE"
        )
        _ = try await sendRaw(request)
    }

    // MARK: - Presets

    /// Recording setting presets and the server's global defaults
    /// (`GET /api/recording/presets`; EDCB backend only).
    ///
    /// The list always contains the `id == 0` default preset.
    public func recordingPresets() async throws -> RecordSettingsPresets {
        try await perform(
            makeRequest(path: ["recording", "presets"]),
            as: RecordSettingsPresets.self
        )
    }

    /// The record settings a new reservation starts with: the `id == 0` preset
    /// of the server, or the web client's hard-coded fallback when the preset
    /// endpoint is unavailable.
    public func defaultRecordSettings() async -> RecordSettings {
        guard let presets = try? await recordingPresets(),
              let defaultPreset = presets.defaultPreset else {
            return RecordSettings.fallback
        }
        return defaultPreset.recordSettings
    }

    // MARK: - Requests

    /// A JSON request with an encoded body. Encoding errors are reported as
    /// decoding errors, like the other request builders of the client.
    private func jsonRequest<T: Encodable>(
        path: [String],
        method: String,
        body: T
    ) throws -> URLRequest {
        let data: Data
        do {
            data = try JSONCoding.encode(body)
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
        return makeRequest(
            path: path,
            method: method,
            body: data,
            contentType: "application/json"
        )
    }
}
