import Darwin
import Foundation
import IOKit

/// One read of each core's load since the previous read.
struct CPUUsage: Equatable {
    /// A core at or above this share of its time counts as busy. An idle Mac's cores tick along
    /// at a few percent, so this separates real work from background noise.
    static let busyThreshold = 0.2

    /// Each logical core's usage, 0...1, in macOS's core order.
    var cores: [Double]
    /// How many cores at the start of `cores` are efficiency cores (0 on Intel). Apple silicon
    /// numbers its efficiency cores first.
    var efficiencyCoreCount: Int

    /// Every core's time averaged: 1 means all cores flat out.
    var total: Double { cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count) }
    var busyCores: Int { cores.filter { $0 >= Self.busyThreshold }.count }
}

/// Memory in use, counted the way Activity Monitor's "Memory Used" does: app memory, wired and
/// compressed. Cached files are not "used": macOS gives them back the moment anything needs them.
struct MemoryUsage: Equatable {
    enum Pressure { case normal, warning, critical }

    var usedBytes: UInt64
    var totalBytes: UInt64
    /// nil where the system won't say (the sandboxed build may not be allowed to read it).
    var pressure: Pressure?

    var fraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
}

struct NetworkRate: Equatable {
    var downBytesPerSecond: Double
    var upBytesPerSecond: Double
}

/// Mach's host port. Asking for it adds a reference each time, so it is asked for once.
private let hostPort = mach_host_self()

/// Reads each core's tick counters and reports the change since the last read. Not thread-safe:
/// use from one queue.
final class CPUSampler {
    private struct Ticks {
        var busy: UInt32
        var total: UInt32
    }

    private var previous: [Ticks] = []
    private let efficiencyCoreCount = CPUSampler.sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    /// nil until there are two reads to compare.
    func sample() -> CPUUsage? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        let current: [Ticks] = (0..<Int(coreCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            let busy = ticks(CPU_STATE_USER) &+ ticks(CPU_STATE_SYSTEM) &+ ticks(CPU_STATE_NICE)
            return Ticks(busy: busy, total: busy &+ ticks(CPU_STATE_IDLE))
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        // Wrapping subtraction: the 32-bit counters roll over on a long-running Mac.
        let cores = zip(previous, current).map { old, new -> Double in
            let total = new.total &- old.total
            return total == 0 ? 0 : min(1, Double(new.busy &- old.busy) / Double(total))
        }
        return CPUUsage(cores: cores, efficiencyCoreCount: min(efficiencyCoreCount, cores.count))
    }

    /// Forgets the last read, so the next usage is not an average over the time since it.
    func reset() {
        previous = []
    }

    fileprivate static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }
}

enum MemoryReader {
    static func read() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(hostPort, &pageSize) == KERN_SUCCESS else { return nil }

        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let usedPages = appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)

        let pressure: MemoryUsage.Pressure?
        switch CPUSampler.sysctlInt("kern.memorystatus_vm_pressure_level") {
        case 1: pressure = .normal
        case 2: pressure = .warning
        case 4: pressure = .critical
        default: pressure = nil
        }
        return MemoryUsage(usedBytes: usedPages * UInt64(pageSize),
                           totalBytes: ProcessInfo.processInfo.physicalMemory,
                           pressure: pressure)
    }
}

/// Bytes through the Mac's Ethernet and Wi-Fi interfaces. VPN tunnels are left out: their traffic
/// also crosses a physical interface and would count twice. Not thread-safe: use from one queue.
final class NetworkSampler {
    private struct Counters {
        var received: UInt32
        var sent: UInt32
    }

    private var previous: [String: Counters] = [:]
    private var previousDate: Date?

    /// nil until there are two reads to compare.
    func sample() -> NetworkRate? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }

        var current: [String: Counters] = [:]
        var cursor = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let data = interface.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            current[name] = Counters(received: data.pointee.ifi_ibytes, sent: data.pointee.ifi_obytes)
        }

        let now = Date()
        defer {
            previous = current
            previousDate = now
        }
        guard let previousDate, now > previousDate else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, counters) in current {
            guard let old = previous[name] else { continue }
            // Wrapping subtraction: these 32-bit counters roll over every 4 GB.
            received += UInt64(counters.received &- old.received)
            sent += UInt64(counters.sent &- old.sent)
        }
        let seconds = now.timeIntervalSince(previousDate)
        return NetworkRate(downBytesPerSecond: Double(received) / seconds, upBytesPerSecond: Double(sent) / seconds)
    }

    func reset() {
        previous = [:]
        previousDate = nil
    }
}

enum DiskReader {
    /// Space left for the user's files, as Finder reports it (it counts what macOS can purge).
    static func freeBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

enum GPUReader {
    /// How busy the GPU is right now, 0...100, or nil where the driver doesn't say.
    static func utilization() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            guard let statistics = property?.takeRetainedValue() as? [String: Any] else { continue }
            if let percent = (statistics["Device Utilization %"] ?? statistics["GPU Activity(%)"]) as? NSNumber {
                return percent.intValue
            }
        }
        return nil
    }
}
