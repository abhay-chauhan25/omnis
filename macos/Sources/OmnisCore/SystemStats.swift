import Darwin
import Foundation

/// How much memory the Mac is using right now.
public struct MemoryUsage: Equatable, Sendable {
    /// Memory in use by apps and the system: active, wired and compressed.
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    /// Swap: memory macOS has written out to disk because it ran short.
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    /// macOS's own verdict, as shown by the colour of Activity Monitor's graph.
    public var pressure: Pressure

    public enum Pressure: String, Sendable {
        case normal, warning, critical, unknown
    }

    public init(usedBytes: UInt64, totalBytes: UInt64, swapUsedBytes: UInt64, swapTotalBytes: UInt64, pressure: Pressure) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pressure = pressure
    }

    /// "14.2 of 24 GB"
    public var memoryLabel: String { "\(Self.gigabytes(usedBytes)) of \(Self.gigabytes(totalBytes)) GB" }

    /// "2.8 of 4 GB", or "none" when nothing has been swapped out.
    public var swapLabel: String {
        swapUsedBytes < 1_048_576 ? "none" : "\(Self.gigabytes(swapUsedBytes)) of \(Self.gigabytes(swapTotalBytes)) GB"
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    public static func pressure(level: Int) -> Pressure {
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    /// Reads the figures from macOS. Cheap: two system calls, no other program is run.
    public static func current() -> MemoryUsage? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(statistics.active_count) + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let haveSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let haveLevel = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0
        return MemoryUsage(usedBytes: pages * UInt64(pageSize), totalBytes: ProcessInfo.processInfo.physicalMemory,
                           swapUsedBytes: haveSwap ? swap.xsu_used : 0, swapTotalBytes: haveSwap ? swap.xsu_total : 0,
                           pressure: haveLevel ? pressure(level: Int(level)) : .unknown)
    }
}

/// Which programs are using the most energy, as Activity Monitor's Energy tab measures it.
public enum EnergyUse {
    public struct Item: Equatable, Sendable, Identifiable {
        public let name: String
        /// The energy impact figure. Higher drains the battery faster.
        public let impact: Double
        public var id: String { name }
    }

    /// Reads the second sample of `top`'s power listing: the first has no figures yet.
    /// Helper processes of one app are added together, and `top` itself is left out.
    public static func parse(_ output: String, limit: Int = 4, minimum: Double = 1) -> [Item] {
        let lines = output.components(separatedBy: "\n")
        guard let header = lines.lastIndex(where: { $0.hasPrefix("COMMAND") && $0.contains("POWER") }) else { return [] }
        var totals: [String: Double] = [:]
        for line in lines[(header + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.lastIndex(of: " "), let impact = Double(trimmed[trimmed.index(after: space)...]) else { continue }
            var name = trimmed[..<space].trimmingCharacters(in: .whitespaces)
            // "Code Helper (Ren" and "Code Helper" belong to "Code".
            if let helper = name.range(of: " Helper") { name = String(name[..<helper.lowerBound]) }
            guard !name.isEmpty, name != "top" else { continue }
            totals[name, default: 0] += impact
        }
        return totals.filter { $0.value >= minimum }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit)
            .map { Item(name: $0.key, impact: ($0.value * 10).rounded() / 10) }
    }

    /// Takes about a second: `top` has to watch for a moment to measure anything.
    public static func current(run: SessionScanner.Runner = SessionScanner.system) -> [Item] {
        parse(run("/usr/bin/top", ["-l", "2", "-n", "12", "-o", "power", "-stats", "command,power", "-s", "1"]))
    }
}
