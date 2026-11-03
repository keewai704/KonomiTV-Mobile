import Foundation
import Network
import Observation

/// App-wide network path monitor.
///
/// Playback picks the cellular quality profile when the device is on a mobile
/// connection. Wi-Fi and wired Ethernet always count as the regular profile
/// (the web client calls it Wi-Fi 回線時).
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isCellular = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(
        label: "com.github.keewai704.KonomiTV.network-monitor"
    )

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isCellular = path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.isCellular = isCellular
            }
        }
        monitor.start(queue: queue)
    }
}
