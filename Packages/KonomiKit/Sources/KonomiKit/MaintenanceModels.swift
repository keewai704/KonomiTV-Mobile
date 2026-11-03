import Foundation

// MARK: - Maintenance

/// Progress of a maintenance task (schemas.MaintenanceTaskStatus).
public struct MaintenanceTaskStatus: Codable, Sendable, Hashable {
    public var isRunning: Bool
    public var processedCount: Int
    public var totalCount: Int
    /// Whether a batch scan found already registered files when it started.
    public var hasRegisteredFiles: Bool

    public init(
        isRunning: Bool = false,
        processedCount: Int = 0,
        totalCount: Int = 0,
        hasRegisteredFiles: Bool = false
    ) {
        self.isRunning = isRunning
        self.processedCount = processedCount
        self.totalCount = totalCount
        self.hasRegisteredFiles = hasRegisteredFiles
    }

    private enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case processedCount = "processed_count"
        case totalCount = "total_count"
        case hasRegisteredFiles = "has_registered_files"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isRunning = container.lenient(Bool.self, forKey: .isRunning) ?? false
        processedCount = container.lenient(Int.self, forKey: .processedCount) ?? 0
        totalCount = container.lenient(Int.self, forKey: .totalCount) ?? 0
        hasRegisteredFiles = container.lenient(Bool.self, forKey: .hasRegisteredFiles) ?? false
    }

    /// The count label the web client shows above a running task.
    public var progressText: String {
        guard totalCount > 0 else {
            return "\(processedCount) 件"
        }
        return "\(processedCount) / \(totalCount) 件"
    }

    /// 0...1, or nil while the total count is unknown (an indeterminate bar).
    public var fractionCompleted: Double? {
        guard totalCount > 0 else { return nil }
        return min(max(Double(processedCount) / Double(totalCount), 0), 1)
    }
}

/// The two log files the maintenance router streams
/// (MaintenanceRouter.LogStreamAPI).
public enum MaintenanceLogType: String, CaseIterable, Sendable, Hashable, Identifiable {
    case server
    case access

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .server: return "サーバーログ"
        case .access: return "アクセスログ"
        }
    }
}

/// The tasks that report progress through a MaintenanceTaskStatus.
public enum MaintenanceTaskKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case batchScan
    case backgroundAnalysis
    case captureScan
    case databaseVacuum

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .batchScan: return "録画フォルダの一括スキャン"
        case .backgroundAnalysis: return "バックグラウンド解析"
        case .captureScan: return "キャプチャフォルダの一括スキャン"
        case .databaseVacuum: return "データベースの最適化"
        }
    }

    /// Path component of the run / status routes (`batch-scan`,
    /// `background-analysis`, `capture-scan`, `database-vacuum`).
    public var pathComponent: String {
        switch self {
        case .batchScan: return "batch-scan"
        case .backgroundAnalysis: return "background-analysis"
        case .captureScan: return "capture-scan"
        case .databaseVacuum: return "database-vacuum"
        }
    }
}
