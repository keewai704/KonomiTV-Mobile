import Foundation

// MARK: - Recording settings

/// Recording mode of a reservation (schemas.RecordSettings.recording_mode).
///
/// The web client keeps this hidden (new reservations always use
/// "SpecifiedService"), but it is part of every request and response body, so
/// it is modelled in full.
public enum RecordingMode: String, Codable, CaseIterable, Sendable, Hashable {
    case allServices = "AllServices"
    case allServicesWithoutDecoding = "AllServicesWithoutDecoding"
    case specifiedService = "SpecifiedService"
    case specifiedServiceWithoutDecoding = "SpecifiedServiceWithoutDecoding"
    case view = "View"

    public var displayName: String {
        switch self {
        case .allServices: return "全サービス"
        case .allServicesWithoutDecoding: return "全サービス (デコードなし)"
        case .specifiedService: return "指定サービスのみ"
        case .specifiedServiceWithoutDecoding: return "指定サービスのみ (デコードなし)"
        case .view: return "視聴"
        }
    }
}

/// Caption / data broadcasting setting of a recording.
///
/// "Default" follows the server's global default; the global defaults
/// themselves only ever use "Enable" / "Disable".
public enum RecordingContentMode: String, Codable, CaseIterable, Sendable, Hashable {
    case useDefault = "Default"
    case enable = "Enable"
    case disable = "Disable"

    public var displayName: String {
        switch self {
        case .useDefault: return "デフォルト設定を使う"
        case .enable: return "録画する"
        case .disable: return "録画しない"
        }
    }
}

/// What the server does after a recording finished.
public enum PostRecordingMode: String, Codable, CaseIterable, Sendable, Hashable {
    case useDefault = "Default"
    case nothing = "Nothing"
    case standby = "Standby"
    case standbyAndReboot = "StandbyAndReboot"
    case suspend = "Suspend"
    case suspendAndReboot = "SuspendAndReboot"
    case shutdown = "Shutdown"

    public var displayName: String {
        switch self {
        case .useDefault: return "デフォルト設定を使う"
        case .nothing: return "何もしない"
        case .standby: return "スタンバイ"
        case .standbyAndReboot: return "スタンバイ (復帰後再起動)"
        case .suspend: return "サスペンド"
        case .suspendAndReboot: return "サスペンド (復帰後再起動)"
        case .shutdown: return "シャットダウン"
        }
    }
}

/// One destination folder of a recording (schemas.RecordingFolder).
public struct RecordingFolder: Codable, Sendable, Hashable {
    public var recordingFolderPath: String
    /// File name macro of RecName_Macro; nil uses the server default.
    public var recordingFileNameTemplate: String?
    public var isOnesegSeparateRecordingFolder: Bool

    public init(
        recordingFolderPath: String = "",
        recordingFileNameTemplate: String? = nil,
        isOnesegSeparateRecordingFolder: Bool = false
    ) {
        self.recordingFolderPath = recordingFolderPath
        self.recordingFileNameTemplate = recordingFileNameTemplate
        self.isOnesegSeparateRecordingFolder = isOnesegSeparateRecordingFolder
    }

    private enum CodingKeys: String, CodingKey {
        case recordingFolderPath = "recording_folder_path"
        case recordingFileNameTemplate = "recording_file_name_template"
        case isOnesegSeparateRecordingFolder = "is_oneseg_separate_recording_folder"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingFolderPath = container.lenient(String.self, forKey: .recordingFolderPath) ?? ""
        recordingFileNameTemplate = container.lenient(String.self, forKey: .recordingFileNameTemplate)
        isOnesegSeparateRecordingFolder =
            container.lenient(Bool.self, forKey: .isOnesegSeparateRecordingFolder) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordingFolderPath, forKey: .recordingFolderPath)
        if let recordingFileNameTemplate {
            try container.encode(recordingFileNameTemplate, forKey: .recordingFileNameTemplate)
        } else {
            try container.encodeNil(forKey: .recordingFileNameTemplate)
        }
        try container.encode(
            isOnesegSeparateRecordingFolder,
            forKey: .isOnesegSeparateRecordingFolder
        )
    }
}

/// Recording settings of a reservation or of a keyword condition
/// (schemas.RecordSettings).
///
/// Every field is sent back on update: the server replaces the whole record
/// setting block, so a field left out would silently reset to its default.
public struct RecordSettings: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    /// 1 (lowest) ... 5 (highest).
    public var priority: Int
    public var recordingFolders: [RecordingFolder]
    /// Seconds before the start; nil follows the global default.
    public var recordingStartMargin: Int?
    /// Seconds after the end; nil follows the global default.
    public var recordingEndMargin: Int?
    public var recordingMode: RecordingMode
    public var captionRecordingMode: RecordingContentMode
    public var dataBroadcastingRecordingMode: RecordingContentMode
    public var postRecordingMode: PostRecordingMode
    public var postRecordingBatFilePath: String?
    public var isEventRelayFollowEnabled: Bool
    public var isExactRecordingEnabled: Bool
    public var isOnesegSeparateOutputEnabled: Bool
    public var isSequentialRecordingInSingleFileEnabled: Bool
    /// Forced tuner; nil picks a tuner automatically.
    public var forcedTunerID: Int?

    public init(
        isEnabled: Bool = true,
        priority: Int = 3,
        recordingFolders: [RecordingFolder] = [],
        recordingStartMargin: Int? = nil,
        recordingEndMargin: Int? = nil,
        recordingMode: RecordingMode = .specifiedService,
        captionRecordingMode: RecordingContentMode = .useDefault,
        dataBroadcastingRecordingMode: RecordingContentMode = .useDefault,
        postRecordingMode: PostRecordingMode = .useDefault,
        postRecordingBatFilePath: String? = nil,
        isEventRelayFollowEnabled: Bool = true,
        isExactRecordingEnabled: Bool = false,
        isOnesegSeparateOutputEnabled: Bool = false,
        isSequentialRecordingInSingleFileEnabled: Bool = false,
        forcedTunerID: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.priority = priority
        self.recordingFolders = recordingFolders
        self.recordingStartMargin = recordingStartMargin
        self.recordingEndMargin = recordingEndMargin
        self.recordingMode = recordingMode
        self.captionRecordingMode = captionRecordingMode
        self.dataBroadcastingRecordingMode = dataBroadcastingRecordingMode
        self.postRecordingMode = postRecordingMode
        self.postRecordingBatFilePath = postRecordingBatFilePath
        self.isEventRelayFollowEnabled = isEventRelayFollowEnabled
        self.isExactRecordingEnabled = isExactRecordingEnabled
        self.isOnesegSeparateOutputEnabled = isOnesegSeparateOutputEnabled
        self.isSequentialRecordingInSingleFileEnabled = isSequentialRecordingInSingleFileEnabled
        self.forcedTunerID = forcedTunerID
    }

    /// The web client's hard-coded fallback (IRecordSettingsDefault), used
    /// when the preset endpoint is unavailable (Mirakurun backend, old server).
    public static let fallback = RecordSettings(priority: 2)

    /// Priority clamped to the range the server accepts (1...5).
    public var clampedPriority: Int { min(max(priority, 1), 5) }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case priority
        case recordingFolders = "recording_folders"
        case recordingStartMargin = "recording_start_margin"
        case recordingEndMargin = "recording_end_margin"
        case recordingMode = "recording_mode"
        case captionRecordingMode = "caption_recording_mode"
        case dataBroadcastingRecordingMode = "data_broadcasting_recording_mode"
        case postRecordingMode = "post_recording_mode"
        case postRecordingBatFilePath = "post_recording_bat_file_path"
        case isEventRelayFollowEnabled = "is_event_relay_follow_enabled"
        case isExactRecordingEnabled = "is_exact_recording_enabled"
        case isOnesegSeparateOutputEnabled = "is_oneseg_separate_output_enabled"
        case isSequentialRecordingInSingleFileEnabled = "is_sequential_recording_in_single_file_enabled"
        case forcedTunerID = "forced_tuner_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.lenient(Bool.self, forKey: .isEnabled) ?? true
        priority = min(max(container.lenient(Int.self, forKey: .priority) ?? 3, 1), 5)
        recordingFolders = container.lenient([RecordingFolder].self, forKey: .recordingFolders) ?? []
        recordingStartMargin = container.lenient(Int.self, forKey: .recordingStartMargin)
        recordingEndMargin = container.lenient(Int.self, forKey: .recordingEndMargin)
        let rawRecordingMode = container.lenient(String.self, forKey: .recordingMode) ?? ""
        recordingMode = RecordingMode(rawValue: rawRecordingMode) ?? .specifiedService
        let rawCaptionMode = container.lenient(String.self, forKey: .captionRecordingMode) ?? ""
        captionRecordingMode = RecordingContentMode(rawValue: rawCaptionMode) ?? .useDefault
        let rawDataMode = container.lenient(String.self, forKey: .dataBroadcastingRecordingMode) ?? ""
        dataBroadcastingRecordingMode = RecordingContentMode(rawValue: rawDataMode) ?? .useDefault
        let rawPostMode = container.lenient(String.self, forKey: .postRecordingMode) ?? ""
        postRecordingMode = PostRecordingMode(rawValue: rawPostMode) ?? .useDefault
        postRecordingBatFilePath = container.lenient(String.self, forKey: .postRecordingBatFilePath)
        isEventRelayFollowEnabled =
            container.lenient(Bool.self, forKey: .isEventRelayFollowEnabled) ?? true
        isExactRecordingEnabled =
            container.lenient(Bool.self, forKey: .isExactRecordingEnabled) ?? false
        isOnesegSeparateOutputEnabled =
            container.lenient(Bool.self, forKey: .isOnesegSeparateOutputEnabled) ?? false
        isSequentialRecordingInSingleFileEnabled =
            container.lenient(Bool.self, forKey: .isSequentialRecordingInSingleFileEnabled) ?? false
        forcedTunerID = container.lenient(Int.self, forKey: .forcedTunerID)
    }

    /// Always encodes every key (null where unset), matching the shape the
    /// server and the web client exchange.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(clampedPriority, forKey: .priority)
        try container.encode(recordingFolders, forKey: .recordingFolders)
        if let recordingStartMargin {
            try container.encode(recordingStartMargin, forKey: .recordingStartMargin)
        } else {
            try container.encodeNil(forKey: .recordingStartMargin)
        }
        if let recordingEndMargin {
            try container.encode(recordingEndMargin, forKey: .recordingEndMargin)
        } else {
            try container.encodeNil(forKey: .recordingEndMargin)
        }
        try container.encode(recordingMode, forKey: .recordingMode)
        try container.encode(captionRecordingMode, forKey: .captionRecordingMode)
        try container.encode(
            dataBroadcastingRecordingMode,
            forKey: .dataBroadcastingRecordingMode
        )
        try container.encode(postRecordingMode, forKey: .postRecordingMode)
        if let postRecordingBatFilePath {
            try container.encode(postRecordingBatFilePath, forKey: .postRecordingBatFilePath)
        } else {
            try container.encodeNil(forKey: .postRecordingBatFilePath)
        }
        try container.encode(isEventRelayFollowEnabled, forKey: .isEventRelayFollowEnabled)
        try container.encode(isExactRecordingEnabled, forKey: .isExactRecordingEnabled)
        try container.encode(isOnesegSeparateOutputEnabled, forKey: .isOnesegSeparateOutputEnabled)
        try container.encode(
            isSequentialRecordingInSingleFileEnabled,
            forKey: .isSequentialRecordingInSingleFileEnabled
        )
        if let forcedTunerID {
            try container.encode(forcedTunerID, forKey: .forcedTunerID)
        } else {
            try container.encodeNil(forKey: .forcedTunerID)
        }
    }
}

/// Global default of a record setting, from EpgTimerSrv.ini's [SET] section
/// (schemas.RecordSettingsGlobalDefaults).
public struct RecordSettingsGlobalDefaults: Codable, Sendable, Hashable {
    public var recordingStartMargin: Int
    public var recordingEndMargin: Int
    public var captionRecordingMode: RecordingContentMode
    public var dataBroadcastingRecordingMode: RecordingContentMode
    public var postRecordingMode: PostRecordingMode

    public init(
        recordingStartMargin: Int = 5,
        recordingEndMargin: Int = 2,
        captionRecordingMode: RecordingContentMode = .enable,
        dataBroadcastingRecordingMode: RecordingContentMode = .disable,
        postRecordingMode: PostRecordingMode = .nothing
    ) {
        self.recordingStartMargin = recordingStartMargin
        self.recordingEndMargin = recordingEndMargin
        self.captionRecordingMode = captionRecordingMode
        self.dataBroadcastingRecordingMode = dataBroadcastingRecordingMode
        self.postRecordingMode = postRecordingMode
    }

    private enum CodingKeys: String, CodingKey {
        case recordingStartMargin = "recording_start_margin"
        case recordingEndMargin = "recording_end_margin"
        case captionRecordingMode = "caption_recording_mode"
        case dataBroadcastingRecordingMode = "data_broadcasting_recording_mode"
        case postRecordingMode = "post_recording_mode"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingStartMargin = container.lenient(Int.self, forKey: .recordingStartMargin) ?? 5
        recordingEndMargin = container.lenient(Int.self, forKey: .recordingEndMargin) ?? 2
        let rawCaptionMode = container.lenient(String.self, forKey: .captionRecordingMode) ?? ""
        captionRecordingMode = RecordingContentMode(rawValue: rawCaptionMode) ?? .enable
        let rawDataMode = container.lenient(String.self, forKey: .dataBroadcastingRecordingMode) ?? ""
        dataBroadcastingRecordingMode = RecordingContentMode(rawValue: rawDataMode) ?? .disable
        let rawPostMode = container.lenient(String.self, forKey: .postRecordingMode) ?? ""
        postRecordingMode = PostRecordingMode(rawValue: rawPostMode) ?? .nothing
    }
}

/// One recording setting preset of the server (schemas.RecordSettingsPreset).
public struct RecordSettingsPreset: Codable, Sendable, Hashable, Identifiable {
    /// 0 is the default preset, which always exists.
    public var id: Int
    public var name: String
    public var recordSettings: RecordSettings

    public init(id: Int = 0, name: String = "", recordSettings: RecordSettings = RecordSettings()) {
        self.id = id
        self.name = name
        self.recordSettings = recordSettings
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case recordSettings = "record_settings"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        name = container.lenient(String.self, forKey: .name) ?? ""
        recordSettings = container.lenient(RecordSettings.self, forKey: .recordSettings) ?? RecordSettings()
    }
}

/// Response of GET /api/recording/presets.
public struct RecordSettingsPresets: Codable, Sendable, Hashable {
    public var globalDefaults: RecordSettingsGlobalDefaults
    public var presets: [RecordSettingsPreset]

    public init(
        globalDefaults: RecordSettingsGlobalDefaults = RecordSettingsGlobalDefaults(),
        presets: [RecordSettingsPreset] = []
    ) {
        self.globalDefaults = globalDefaults
        self.presets = presets
    }

    /// The id == 0 default preset, when the server returned one.
    public var defaultPreset: RecordSettingsPreset? {
        presets.first { $0.id == 0 }
    }

    private enum CodingKeys: String, CodingKey {
        case globalDefaults = "global_defaults"
        case presets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        globalDefaults =
            container.lenient(RecordSettingsGlobalDefaults.self, forKey: .globalDefaults)
            ?? RecordSettingsGlobalDefaults()
        presets = container.lenient([RecordSettingsPreset].self, forKey: .presets) ?? []
    }
}

// MARK: - Reservations

/// Whether the server can actually record a reserved program
/// (schemas.Reservation.recording_availability).
public enum RecordingAvailability: String, Codable, CaseIterable, Sendable, Hashable {
    case full = "Full"
    case partial = "Partial"
    case unavailable = "Unavailable"

    public var displayName: String {
        switch self {
        case .full: return "録画可能"
        case .partial: return "一部のみ録画可能"
        case .unavailable: return "チューナー不足"
        }
    }
}

/// A recording reservation (schemas.Reservation).
public struct Reservation: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var channel: Channel
    public var program: Program
    public var isRecordingInProgress: Bool
    public var recordingAvailability: RecordingAvailability
    /// "EPG自動予約" when a keyword condition created the reservation.
    public var comment: String
    public var scheduledRecordingFileName: String
    /// Estimated file size in bytes, calculated from the server's bitrates.
    public var estimatedRecordingFileSize: Int
    public var recordSettings: RecordSettings

    public init(
        id: Int = 0,
        channel: Channel = Channel(),
        program: Program = Program(),
        isRecordingInProgress: Bool = false,
        recordingAvailability: RecordingAvailability = .full,
        comment: String = "",
        scheduledRecordingFileName: String = "",
        estimatedRecordingFileSize: Int = 0,
        recordSettings: RecordSettings = RecordSettings()
    ) {
        self.id = id
        self.channel = channel
        self.program = program
        self.isRecordingInProgress = isRecordingInProgress
        self.recordingAvailability = recordingAvailability
        self.comment = comment
        self.scheduledRecordingFileName = scheduledRecordingFileName
        self.estimatedRecordingFileSize = estimatedRecordingFileSize
        self.recordSettings = recordSettings
    }

    /// True when a keyword condition (EPG 自動予約) created this reservation.
    public var isKeywordAutoReservation: Bool {
        comment.contains("EPG自動予約")
    }

    /// True when the reservation does not record anything.
    public var isDisabled: Bool { !recordSettings.isEnabled }

    /// Priority clamped to the range the server accepts (1...5).
    public var priority: Int { recordSettings.clampedPriority }

    private enum CodingKeys: String, CodingKey {
        case id
        case channel
        case program
        case isRecordingInProgress = "is_recording_in_progress"
        case recordingAvailability = "recording_availability"
        case comment
        case scheduledRecordingFileName = "scheduled_recording_file_name"
        case estimatedRecordingFileSize = "estimated_recording_file_size"
        case recordSettings = "record_settings"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        channel = container.lenient(Channel.self, forKey: .channel) ?? Channel()
        program = container.lenient(Program.self, forKey: .program) ?? Program()
        isRecordingInProgress =
            container.lenient(Bool.self, forKey: .isRecordingInProgress) ?? false
        let rawAvailability = container.lenient(String.self, forKey: .recordingAvailability) ?? ""
        recordingAvailability = RecordingAvailability(rawValue: rawAvailability) ?? .full
        comment = container.lenient(String.self, forKey: .comment) ?? ""
        scheduledRecordingFileName =
            container.lenient(String.self, forKey: .scheduledRecordingFileName) ?? ""
        estimatedRecordingFileSize =
            container.lenient(Int.self, forKey: .estimatedRecordingFileSize) ?? 0
        recordSettings =
            container.lenient(RecordSettings.self, forKey: .recordSettings) ?? RecordSettings()
    }
}

/// Response of GET /api/recording/reservations.
public struct Reservations: Codable, Sendable, Hashable {
    public var total: Int
    public var reservations: [Reservation]

    public init(total: Int = 0, reservations: [Reservation] = []) {
        self.total = total
        self.reservations = reservations
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case reservations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.lenient(Int.self, forKey: .total) ?? 0
        reservations = container.lenient([Reservation].self, forKey: .reservations) ?? []
    }
}

/// Minimal program information of a reservation whose program is not in the
/// server's database yet (an EIT[p/f] program)
/// (schemas.ReservationAddProgram).
public struct ReservationAddProgram: Codable, Sendable, Hashable {
    public var id: String
    public var channelID: String
    public var networkID: Int
    public var serviceID: Int
    public var eventID: Int
    public var title: String
    public var startTime: Date
    public var duration: Double

    public init(
        id: String = "",
        channelID: String = "",
        networkID: Int = 0,
        serviceID: Int = 0,
        eventID: Int = 0,
        title: String = "",
        startTime: Date = Date(timeIntervalSince1970: 0),
        duration: Double = 0
    ) {
        self.id = id
        self.channelID = channelID
        self.networkID = networkID
        self.serviceID = serviceID
        self.eventID = eventID
        self.title = title
        self.startTime = startTime
        self.duration = duration
    }

    /// The payload of a program the client already holds, so programs that are
    /// not in the server's database can be reserved as well.
    public init(program: Program) {
        self.init(
            id: program.id,
            channelID: program.channelID,
            networkID: program.networkID ?? 0,
            serviceID: program.serviceID ?? 0,
            eventID: program.eventID ?? 0,
            title: program.title,
            startTime: program.startTime,
            duration: program.duration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case channelID = "channel_id"
        case networkID = "network_id"
        case serviceID = "service_id"
        case eventID = "event_id"
        case title
        case startTime = "start_time"
        case duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(String.self, forKey: .id) ?? ""
        channelID = container.lenient(String.self, forKey: .channelID) ?? ""
        networkID = container.lenient(Int.self, forKey: .networkID) ?? 0
        serviceID = container.lenient(Int.self, forKey: .serviceID) ?? 0
        eventID = container.lenient(Int.self, forKey: .eventID) ?? 0
        title = container.lenient(String.self, forKey: .title) ?? ""
        startTime = container.lenient(Date.self, forKey: .startTime) ?? Date(timeIntervalSince1970: 0)
        duration = container.lenient(Double.self, forKey: .duration) ?? 0
    }
}

/// Body of POST /api/recording/reservations.
public struct ReservationAddRequest: Codable, Sendable, Hashable {
    public var programID: String
    public var recordSettings: RecordSettings
    public var program: ReservationAddProgram?

    public init(
        programID: String,
        recordSettings: RecordSettings,
        program: ReservationAddProgram? = nil
    ) {
        self.programID = programID
        self.recordSettings = recordSettings
        self.program = program
    }

    private enum CodingKeys: String, CodingKey {
        case programID = "program_id"
        case recordSettings = "record_settings"
        case program
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(programID, forKey: .programID)
        try container.encode(recordSettings, forKey: .recordSettings)
        if let program {
            try container.encode(program, forKey: .program)
        } else {
            try container.encodeNil(forKey: .program)
        }
    }
}

/// Body of PUT /api/recording/reservations/{id}.
public struct ReservationUpdateRequest: Codable, Sendable, Hashable {
    public var recordSettings: RecordSettings

    public init(recordSettings: RecordSettings) {
        self.recordSettings = recordSettings
    }

    private enum CodingKeys: String, CodingKey {
        case recordSettings = "record_settings"
    }
}

// MARK: - Keyword conditions (EPG 自動予約)

/// A keyword recording condition (schemas.ReservationCondition).
public struct ReservationCondition: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Reservations this condition created.
    public var reservationCount: Int
    public var programSearchCondition: ProgramSearchCondition
    public var recordSettings: RecordSettings

    public init(
        id: Int = 0,
        reservationCount: Int = 0,
        programSearchCondition: ProgramSearchCondition = ProgramSearchCondition(),
        recordSettings: RecordSettings = RecordSettings()
    ) {
        self.id = id
        self.reservationCount = reservationCount
        self.programSearchCondition = programSearchCondition
        self.recordSettings = recordSettings
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case reservationCount = "reservation_count"
        case programSearchCondition = "program_search_condition"
        case recordSettings = "record_settings"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(Int.self, forKey: .id) ?? 0
        reservationCount = container.lenient(Int.self, forKey: .reservationCount) ?? 0
        programSearchCondition =
            container.lenient(ProgramSearchCondition.self, forKey: .programSearchCondition)
            ?? ProgramSearchCondition()
        recordSettings =
            container.lenient(RecordSettings.self, forKey: .recordSettings) ?? RecordSettings()
    }
}

/// Response of GET /api/recording/conditions.
public struct ReservationConditions: Codable, Sendable, Hashable {
    public var total: Int
    public var reservationConditions: [ReservationCondition]

    public init(total: Int = 0, reservationConditions: [ReservationCondition] = []) {
        self.total = total
        self.reservationConditions = reservationConditions
    }

    private enum CodingKeys: String, CodingKey {
        case total
        case reservationConditions = "reservation_conditions"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = container.lenient(Int.self, forKey: .total) ?? 0
        reservationConditions =
            container.lenient([ReservationCondition].self, forKey: .reservationConditions) ?? []
    }
}

/// Body of POST /api/recording/conditions and
/// PUT /api/recording/conditions/{id} (schemas.ReservationConditionAddRequest
/// and ReservationConditionUpdateRequest).
public struct ReservationConditionRequest: Codable, Sendable, Hashable {
    public var programSearchCondition: ProgramSearchCondition
    public var recordSettings: RecordSettings

    public init(
        programSearchCondition: ProgramSearchCondition,
        recordSettings: RecordSettings
    ) {
        self.programSearchCondition = programSearchCondition
        self.recordSettings = recordSettings
    }

    private enum CodingKeys: String, CodingKey {
        case programSearchCondition = "program_search_condition"
        case recordSettings = "record_settings"
    }
}
