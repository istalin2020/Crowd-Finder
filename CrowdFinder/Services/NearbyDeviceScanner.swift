import CoreBluetooth
import Observation

/// Counts Bluetooth devices around the user (phones, watches, earbuds, …) for a few seconds.
///
/// More devices nearby usually means more people. It is a **rough guide** – many phones
/// don't advertise all the time – so it only suggests a level; the person still chooses.
/// Nothing is stored or sent anywhere.
@MainActor
@Observable
final class NearbyDeviceScanner: NSObject, CBCentralManagerDelegate {
    enum State: Equatable {
        case idle
        case scanning(secondsLeft: Int)
        case finished(deviceCount: Int)
        case unavailable(String)
    }

    private(set) var state: State = .idle

    /// Device counts treated as the top of quiet / moderate / busy (above = very busy).
    static let thresholds = (quiet: 5, moderate: 15, busy: 35)
    static let scanSeconds = 12
    /// Ignore far-away devices (roughly beyond 15–20 m).
    nonisolated static let minimumRSSI = -85

    private var manager: CBCentralManager?
    private var seen: Set<UUID> = []
    private var timerTask: Task<Void, Never>?

    var suggestedLevel: CrowdLevel? {
        guard case .finished(let count) = state else { return nil }
        return Self.level(forDeviceCount: count)
    }

    static func level(forDeviceCount count: Int) -> CrowdLevel {
        switch count {
        case ...thresholds.quiet: .quiet
        case ...thresholds.moderate: .moderate
        case ...thresholds.busy: .busy
        default: .veryBusy
        }
    }

    func start() {
        stop()
        seen = []
        if manager == nil {
            // Creating the manager shows the Bluetooth permission prompt the first time.
            manager = CBCentralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn {
            beginScan()
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        manager?.stopScan()
    }

    private func beginScan() {
        guard let manager else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning(secondsLeft: Self.scanSeconds)
        timerTask = Task { [weak self] in
            for second in stride(from: Self.scanSeconds - 1, through: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.state = second == 0 ? .finished(deviceCount: self.seen.count) : .scanning(secondsLeft: second)
            }
            self?.manager?.stopScan()
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let managerState = central.state
        Task { @MainActor in
            switch managerState {
            case .poweredOn:
                if case .scanning = self.state { return }
                if self.timerTask == nil { self.beginScan() }
            case .unauthorized:
                self.state = .unavailable("Bluetooth access is off for Crowd Finder. Turn it on in Settings.")
            case .poweredOff:
                self.state = .unavailable("Turn on Bluetooth to measure.")
            case .unsupported:
                self.state = .unavailable("Bluetooth is not available on this device.")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let identifier = peripheral.identifier
        let strength = RSSI.integerValue
        // 127 means "not available"; ignore weak (far) signals.
        guard strength != 127, strength >= Self.minimumRSSI else { return }
        Task { @MainActor in self.seen.insert(identifier) }
    }
}
