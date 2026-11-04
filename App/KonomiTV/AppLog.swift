import OSLog

/// Unified logging of the app. CI streams the subsystem from the simulator
/// and prints the lines of each failed UI test (see `scripts/report-ui-tests.py`),
/// so the messages are written at `notice` level with public values.
enum AppLog {
    static let subsystem = "com.github.keewai704.KonomiTV"
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let comments = Logger(subsystem: subsystem, category: "comments")
    static let hls = Logger(subsystem: subsystem, category: "hls")
    static let vlc = Logger(subsystem: subsystem, category: "vlc")
    static let dataBroadcasting = Logger(subsystem: subsystem, category: "bml")
}
