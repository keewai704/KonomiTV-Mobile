import Foundation

// MARK: - Server settings

/// The backend the server receives broadcast waves from
/// (app.config._ServerSettingsGeneral.backend).
public enum ServerBackend: String, Codable, CaseIterable, Sendable, Hashable {
    case edcb = "EDCB"
    case mirakurun = "Mirakurun"

    public var displayName: String { rawValue }
}

/// The encoder the server uses for live streaming
/// (app.config._ServerSettingsGeneral.encoder).
public enum ServerEncoder: String, Codable, CaseIterable, Sendable, Hashable {
    case ffmpeg = "FFmpeg"
    case qsv = "QSVEncC"
    case nvenc = "NVEncC"
    case vce = "VCEEncC"
    case rkmpp = "rkmppenc"

    public var displayName: String {
        switch self {
        case .ffmpeg: return "FFmpeg (ソフトウェア)"
        case .qsv: return "QSVEncC (Intel)"
        case .nvenc: return "NVEncC (NVIDIA)"
        case .vce: return "VCEEncC (AMD)"
        case .rkmpp: return "rkmppenc (Rockchip)"
        }
    }
}

/// Every setting the web client's views/Settings/Server.vue edits, with the
/// same sections and defaults (app.config.ServerSettings).
///
/// The server serialises `custom_https_certificate` and the other optional
/// paths as `null`; the model keeps them as optionals and the app writes
/// `null` back, like the web client does before saving.
public struct ServerSettings: Codable, Sendable, Hashable {

    public struct General: Codable, Sendable, Hashable {
        public var backend: ServerBackend
        public var alwaysReceiveTVFromMirakurun: Bool
        public var edcbURL: String
        public var mirakurunURL: String
        public var encoder: ServerEncoder
        /// Minutes between EPG updates (0.5...60).
        public var programUpdateInterval: Double
        public var debug: Bool
        public var debugEncoder: Bool

        public init(
            backend: ServerBackend = .edcb,
            alwaysReceiveTVFromMirakurun: Bool = false,
            edcbURL: String = "tcp://127.0.0.1:4510/",
            mirakurunURL: String = "http://127.0.0.1:40772/",
            encoder: ServerEncoder = .ffmpeg,
            programUpdateInterval: Double = 5.0,
            debug: Bool = false,
            debugEncoder: Bool = false
        ) {
            self.backend = backend
            self.alwaysReceiveTVFromMirakurun = alwaysReceiveTVFromMirakurun
            self.edcbURL = edcbURL
            self.mirakurunURL = mirakurunURL
            self.encoder = encoder
            self.programUpdateInterval = programUpdateInterval
            self.debug = debug
            self.debugEncoder = debugEncoder
        }

        private enum CodingKeys: String, CodingKey {
            case backend
            case alwaysReceiveTVFromMirakurun = "always_receive_tv_from_mirakurun"
            case edcbURL = "edcb_url"
            case mirakurunURL = "mirakurun_url"
            case encoder
            case programUpdateInterval = "program_update_interval"
            case debug
            case debugEncoder = "debug_encoder"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = General()
            let rawBackend = container.lenient(String.self, forKey: .backend) ?? ""
            backend = ServerBackend(rawValue: rawBackend) ?? defaults.backend
            alwaysReceiveTVFromMirakurun =
                container.lenient(Bool.self, forKey: .alwaysReceiveTVFromMirakurun)
                ?? defaults.alwaysReceiveTVFromMirakurun
            edcbURL = container.lenient(String.self, forKey: .edcbURL) ?? defaults.edcbURL
            mirakurunURL = container.lenient(String.self, forKey: .mirakurunURL)
                ?? defaults.mirakurunURL
            let rawEncoder = container.lenient(String.self, forKey: .encoder) ?? ""
            encoder = ServerEncoder(rawValue: rawEncoder) ?? defaults.encoder
            programUpdateInterval =
                container.lenient(Double.self, forKey: .programUpdateInterval)
                ?? defaults.programUpdateInterval
            debug = container.lenient(Bool.self, forKey: .debug) ?? defaults.debug
            debugEncoder = container.lenient(Bool.self, forKey: .debugEncoder)
                ?? defaults.debugEncoder
        }
    }

    public struct Server: Codable, Sendable, Hashable {
        public var port: Int
        public var customHTTPSCertificate: String?
        public var customHTTPSPrivateKey: String?

        public init(
            port: Int = 7000,
            customHTTPSCertificate: String? = nil,
            customHTTPSPrivateKey: String? = nil
        ) {
            self.port = port
            self.customHTTPSCertificate = customHTTPSCertificate
            self.customHTTPSPrivateKey = customHTTPSPrivateKey
        }

        private enum CodingKeys: String, CodingKey {
            case port
            case customHTTPSCertificate = "custom_https_certificate"
            case customHTTPSPrivateKey = "custom_https_private_key"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            port = container.lenient(Int.self, forKey: .port) ?? 7000
            customHTTPSCertificate = container.lenient(String.self, forKey: .customHTTPSCertificate)
            customHTTPSPrivateKey = container.lenient(String.self, forKey: .customHTTPSPrivateKey)
        }
    }

    public struct TV: Codable, Sendable, Hashable {
        /// A region from `TerrestrialRegionCatalog`; nil means unset.
        public var preferredTerrestrialRegion: String?
        /// Seconds an unused encoder task is kept alive (0...60).
        public var maxAliveTime: Int
        public var debugModeTSPath: String?

        public init(
            preferredTerrestrialRegion: String? = nil,
            maxAliveTime: Int = 10,
            debugModeTSPath: String? = nil
        ) {
            self.preferredTerrestrialRegion = preferredTerrestrialRegion
            self.maxAliveTime = maxAliveTime
            self.debugModeTSPath = debugModeTSPath
        }

        private enum CodingKeys: String, CodingKey {
            case preferredTerrestrialRegion = "preferred_terrestrial_region"
            case maxAliveTime = "max_alive_time"
            case debugModeTSPath = "debug_mode_ts_path"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preferredTerrestrialRegion =
                container.lenient(String.self, forKey: .preferredTerrestrialRegion)
            maxAliveTime = container.lenient(Int.self, forKey: .maxAliveTime) ?? 10
            debugModeTSPath = container.lenient(String.self, forKey: .debugModeTSPath)
        }
    }

    public struct Video: Codable, Sendable, Hashable {
        public var recordedFolders: [String]
        public var excludeScanPaths: [String]
        /// Minutes between scans of network folders (0.5...60).
        public var recordedFoldersPollingInterval: Double

        public init(
            recordedFolders: [String] = [],
            excludeScanPaths: [String] = [],
            recordedFoldersPollingInterval: Double = 5.0
        ) {
            self.recordedFolders = recordedFolders
            self.excludeScanPaths = excludeScanPaths
            self.recordedFoldersPollingInterval = recordedFoldersPollingInterval
        }

        private enum CodingKeys: String, CodingKey {
            case recordedFolders = "recorded_folders"
            case excludeScanPaths = "exclude_scan_paths"
            case recordedFoldersPollingInterval = "recorded_folders_polling_interval"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            recordedFolders = container.lenient([String].self, forKey: .recordedFolders) ?? []
            excludeScanPaths = container.lenient([String].self, forKey: .excludeScanPaths) ?? []
            recordedFoldersPollingInterval =
                container.lenient(Double.self, forKey: .recordedFoldersPollingInterval) ?? 5.0
        }
    }

    public struct Capture: Codable, Sendable, Hashable {
        public var uploadFolders: [String]
        /// The web client's capture settings screen edits this value, not the
        /// server settings screen; it is kept so saving never resets it.
        public var uploadFoldersPollingInterval: Double

        public init(
            uploadFolders: [String] = [],
            uploadFoldersPollingInterval: Double = 0.0
        ) {
            self.uploadFolders = uploadFolders
            self.uploadFoldersPollingInterval = uploadFoldersPollingInterval
        }

        private enum CodingKeys: String, CodingKey {
            case uploadFolders = "upload_folders"
            case uploadFoldersPollingInterval = "upload_folders_polling_interval"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uploadFolders = container.lenient([String].self, forKey: .uploadFolders) ?? []
            uploadFoldersPollingInterval =
                container.lenient(Double.self, forKey: .uploadFoldersPollingInterval) ?? 0.0
        }
    }

    public var general: General
    public var server: Server
    public var tv: TV
    public var video: Video
    public var capture: Capture

    public init(
        general: General = General(),
        server: Server = Server(),
        tv: TV = TV(),
        video: Video = Video(),
        capture: Capture = Capture()
    ) {
        self.general = general
        self.server = server
        self.tv = tv
        self.video = video
        self.capture = capture
    }

    private enum CodingKeys: String, CodingKey {
        case general
        case server
        case tv
        case video
        case capture
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        general = container.lenient(General.self, forKey: .general) ?? General()
        server = container.lenient(Server.self, forKey: .server) ?? Server()
        tv = container.lenient(TV.self, forKey: .tv) ?? TV()
        video = container.lenient(Video.self, forKey: .video) ?? Video()
        capture = container.lenient(Capture.self, forKey: .capture) ?? Capture()
    }

    /// The distance between the smallest and largest accepted listen port
    /// (app.config._ServerSettingsServer.validate_port).
    public static let portRange = 1024...65525

    /// The web client's URL fields become `null` when left empty.
    public mutating func normalizeOptionalPaths() {
        if server.customHTTPSCertificate?.isEmpty == true {
            server.customHTTPSCertificate = nil
        }
        if server.customHTTPSPrivateKey?.isEmpty == true {
            server.customHTTPSPrivateKey = nil
        }
        if tv.debugModeTSPath?.isEmpty == true {
            tv.debugModeTSPath = nil
        }
        video.recordedFolders = video.recordedFolders.filter { !$0.isEmpty }
        video.excludeScanPaths = video.excludeScanPaths.filter { !$0.isEmpty }
        capture.uploadFolders = capture.uploadFolders.filter { !$0.isEmpty }
    }

    /// The checks the app applies before saving, mirroring the server's
    /// validators (port range and the non-zero polling intervals).
    public func validationError() -> String? {
        if !Self.portRange.contains(server.port) {
            return "リッスンポートは 1024〜65525 の範囲で指定してください。"
        }
        if general.programUpdateInterval < 0.1 {
            return "番組情報の更新間隔は 0.1 分以上にしてください。"
        }
        if video.recordedFoldersPollingInterval < 0.1 {
            return "録画フォルダの確認間隔は 0.1 分以上にしてください。"
        }
        if capture.uploadFoldersPollingInterval < 0 {
            return "キャプチャフォルダの確認間隔は 0 分以上にしてください。"
        }
        if general.backend == .edcb, !general.edcbURL.hasPrefix("tcp://") {
            return "EDCB の TCP API の URL は tcp:// で始まる必要があります。"
        }
        if general.backend == .mirakurun,
           !(general.mirakurunURL.hasPrefix("http://")
             || general.mirakurunURL.hasPrefix("https://")) {
            return "Mirakurun / mirakc の HTTP API の URL は http:// か https:// で始まる必要があります。"
        }
        return nil
    }
}

/// The regions the server accepts for
/// `tv.preferred_terrestrial_region` (app.utils.TSInformation.TerrestrialRegion).
public enum TerrestrialRegionCatalog {
    public static let all: [String] = [
        "北海道（札幌）",
        "北海道（函館）",
        "北海道（旭川）",
        "北海道（帯広）",
        "北海道（釧路）",
        "北海道（北見）",
        "北海道（室蘭）",
        "青森県",
        "岩手県",
        "宮城県",
        "秋田県",
        "山形県",
        "福島県",
        "茨城県",
        "栃木県",
        "群馬県",
        "埼玉県",
        "千葉県",
        "東京都",
        "神奈川県",
        "新潟県",
        "富山県",
        "石川県",
        "福井県",
        "山梨県",
        "長野県",
        "岐阜県",
        "静岡県",
        "愛知県",
        "三重県",
        "滋賀県",
        "京都府",
        "大阪府",
        "兵庫県",
        "奈良県",
        "和歌山県",
        "鳥取県",
        "島根県",
        "岡山県",
        "広島県",
        "山口県",
        "徳島県",
        "香川県",
        "愛媛県",
        "高知県",
        "福岡県",
        "佐賀県",
        "長崎県",
        "熊本県",
        "大分県",
        "宮崎県",
        "鹿児島県",
        "沖縄県",
    ]
}
