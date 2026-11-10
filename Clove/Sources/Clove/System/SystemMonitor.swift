import Foundation

/// Battery and performance readings for the island's System page.
///
/// Samples only while the island is open (`start` / `stop`), on a background queue: a performance
/// monitor must not cost performance, and nobody is looking while the island is closed. The
/// reads themselves are cheap (about 0.2 ms, battery 2 ms); disk is the slow one, so it is read
/// rarely and space on a disk barely moves anyway.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var battery: BatteryReading?
    @Published private(set) var cpu: CPUUsage?
    @Published private(set) var memory: MemoryUsage?
    @Published private(set) var gpuPercent: Int?
    @Published private(set) var network: NetworkRate?
    @Published private(set) var diskFreeBytes: Int64?
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState

    /// When the Mac was last plugged in, if it is plugged in: lets the page say "Connecting" while
    /// the charger negotiates, rather than "No power in".
    private let pluggedInAt: () -> Date?
    private let queue = DispatchQueue(label: "app.clove.system", qos: .utility)
    private let sampler = Sampler()
    private var timer: DispatchSourceTimer?

    init(pluggedInAt: @escaping () -> Date?) {
        self.pluggedInAt = pluggedInAt
        // Read now, so the System page has something to show the moment it first opens.
        battery = BatteryReader.read()
        memory = MemoryReader.read()
    }

    var powerState: PowerState? {
        battery.map { PowerState($0, pluggedInAt: pluggedInAt()) }
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let sampler = sampler
        // A baseline now and the first real figures a moment later, so the page fills in quickly.
        // After that, once a second.
        queue.async { sampler.begin() }
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            let reading = sampler.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(reading) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func apply(_ reading: Sampler.Reading) {
        // Unchanged values are not re-assigned, so the pages only redraw for real changes. Values a
        // tick didn't read (nil) keep what is on screen.
        func update<Value: Equatable>(_ path: ReferenceWritableKeyPath<SystemMonitor, Value?>, _ value: Value?) {
            if let value, self[keyPath: path] != value { self[keyPath: path] = value }
        }
        update(\.battery, reading.battery)
        update(\.cpu, reading.cpu)
        update(\.memory, reading.memory)
        update(\.gpuPercent, reading.gpuPercent)
        update(\.network, reading.network)
        update(\.diskFreeBytes, reading.diskFreeBytes)
        if thermalState != reading.thermalState { thermalState = reading.thermalState }
    }
}

/// The reads themselves, confined to the monitor's serial queue.
private final class Sampler: @unchecked Sendable {
    struct Reading {
        var battery: BatteryReading?
        var cpu: CPUUsage?
        var memory: MemoryUsage?
        var gpuPercent: Int?
        var network: NetworkRate?
        var diskFreeBytes: Int64?
        var thermalState: ProcessInfo.ThermalState
    }

    private static let batteryEvery = 2  // ticks
    private static let diskEvery = 30    // ticks

    private let cpu = CPUSampler()
    private let network = NetworkSampler()
    private var tick = 0

    /// Starts a new measuring window. Without this, the first usage after the island reopens
    /// would be an average over the whole time it was closed.
    func begin() {
        cpu.reset()
        network.reset()
        _ = cpu.sample()
        _ = network.sample()
        tick = 0
    }

    func sample() -> Reading {
        defer { tick += 1 }
        return Reading(
            battery: tick % Self.batteryEvery == 0 ? BatteryReader.read() : nil,
            cpu: cpu.sample(),
            memory: MemoryReader.read(),
            gpuPercent: GPUReader.utilization(),
            network: network.sample(),
            diskFreeBytes: tick % Self.diskEvery == 0 ? DiskReader.freeBytes() : nil,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }
}
