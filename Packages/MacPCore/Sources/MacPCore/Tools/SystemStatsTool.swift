import AppKit
import Darwin
import Foundation
import IOKit.ps

/// Collects native macOS battery, CPU, memory, disk, appearance, and thermal statistics using IOKit and Mach APIs.
public struct SystemStatsTool: MCPTool {
    public let name = "macos_system_stats"
    public let displayName = "Stats Système"
    public let shortSubtitle = "CPU, RAM, Batterie, Disque"
    public let symbolName = "gauge.with.dots.needle.67percent"
    public let category: ToolCategory = .workspace
    public let description = "Retrieves native macOS battery status, real-time CPU usage, load averages, memory usage, disk space, appearance mode, uptime, and thermal state."
    public let sensitivity: ToolSensitivity = .standard
    public let permissionReason = "Lecture seule des statistiques matérielles de ce Mac."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Statistiques système macOS",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [:],
            "additionalProperties": false
        ]
    }

    public struct BatteryStats: Sendable, Codable, Equatable {
        public let hasBattery: Bool
        public let percentage: Int?
        public let isCharging: Bool?
        public let isCharged: Bool?
        public let powerSource: String
        public let timeRemainingMinutes: Int?
    }

    public struct CPUStats: Sendable, Codable, Equatable {
        public let logicalCores: Int
        public let activeCores: Int
        public let usagePercent: Double?
        public let loadAverage1m: Double?
        public let loadAverage5m: Double?
        public let loadAverage15m: Double?
    }

    public struct MemoryStats: Sendable, Codable, Equatable {
        public let totalGB: Double
        public let usedGB: Double
        public let freeGB: Double
        public let usagePercent: Double
    }

    public struct DiskStats: Sendable, Codable, Equatable {
        public let totalGB: Double
        public let availableGB: Double
        public let usedGB: Double
        public let usagePercent: Double
    }

    public struct SystemStatsPayload: Sendable, Codable, Equatable {
        public let hostName: String
        public let macOSVersion: String
        public let uptimeSeconds: Int
        public let thermalState: String
        public let lowPowerModeEnabled: Bool
        public let appearance: String
        public let battery: BatteryStats
        public let cpu: CPUStats
        public let memory: MemoryStats
        public let disk: DiskStats?
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let payload = await Self.collectSnapshot()
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }

    /// Collects a full native macOS telemetry snapshot (also used directly by the live Bento Dashboard!).
    public static func collectSnapshot() async -> SystemStatsPayload {
        let cpuSample = await collectCPUStats()
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return SystemStatsPayload(
            hostName: ProcessInfo.processInfo.hostName,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime),
            thermalState: thermalStateDescription(ProcessInfo.processInfo.thermalState),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            appearance: isDark ? "dark" : "light",
            battery: collectBatteryStats(),
            cpu: cpuSample,
            memory: collectMemoryStats(),
            disk: collectDiskStats()
        )
    }

    // MARK: - Battery (IOKit)

    public static func collectBatteryStats() -> BatteryStats {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            return BatteryStats(
                hasBattery: false,
                percentage: nil,
                isCharging: nil,
                isCharged: nil,
                powerSource: "AC Power",
                timeRemainingMinutes: nil
            )
        }

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let type = desc[kIOPSTypeKey as String] as? String
            if type == kIOPSInternalBatteryType as String || desc[kIOPSCurrentCapacityKey as String] != nil {
                let current = desc[kIOPSCurrentCapacityKey as String] as? Int
                let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int
                let percentage: Int?
                if let current, let maxCap, maxCap > 0 {
                    percentage = Int((Double(current) / Double(maxCap) * 100.0).rounded())
                } else {
                    percentage = current
                }

                let isCharging = desc[kIOPSIsChargingKey as String] as? Bool
                let isCharged = desc[kIOPSIsChargedKey as String] as? Bool
                let powerSource = (desc[kIOPSPowerSourceStateKey as String] as? String) ?? "Unknown"

                let rawTime: Int?
                if isCharging == true {
                    rawTime = desc[kIOPSTimeToFullChargeKey as String] as? Int
                } else {
                    rawTime = desc[kIOPSTimeToEmptyKey as String] as? Int
                }
                let timeRemaining = (rawTime != nil && rawTime! >= 0) ? rawTime : nil

                return BatteryStats(
                    hasBattery: true,
                    percentage: percentage,
                    isCharging: isCharging,
                    isCharged: isCharged,
                    powerSource: powerSource,
                    timeRemainingMinutes: timeRemaining
                )
            }
        }

        return BatteryStats(
            hasBattery: false,
            percentage: nil,
            isCharging: nil,
            isCharged: nil,
            powerSource: "AC Power",
            timeRemainingMinutes: nil
        )
    }

    // MARK: - CPU (Mach host_statistics + getloadavg)

    private struct CPUTicks: Sendable {
        let user: UInt64
        let system: UInt64
        let idle: UInt64
        let nice: UInt64

        var total: UInt64 { user &+ system &+ idle &+ nice }
        var active: UInt64 { user &+ system &+ nice }
    }

    private static func readCPUTicks() -> CPUTicks? {
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var cpuLoadInfo = host_cpu_load_info_data_t()

        let result = withUnsafeMutablePointer(to: &cpuLoadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(cpuLoadInfo.cpu_ticks.0),
            system: UInt64(cpuLoadInfo.cpu_ticks.1),
            idle: UInt64(cpuLoadInfo.cpu_ticks.2),
            nice: UInt64(cpuLoadInfo.cpu_ticks.3)
        )
    }

    public static func collectCPUStats() async -> CPUStats {
        let first = readCPUTicks()
        try? await Task.sleep(for: .milliseconds(150))
        var second = readCPUTicks()

        if let first, let s = second, s.total == first.total {
            try? await Task.sleep(for: .milliseconds(100))
            second = readCPUTicks()
        }

        var usagePercent: Double?
        if let first, let second {
            let deltaTotal = second.total >= first.total ? (second.total - first.total) : 0
            let deltaActive = second.active >= first.active ? (second.active - first.active) : 0
            if deltaTotal > 0 {
                let raw = (Double(deltaActive) / Double(deltaTotal)) * 100.0
                usagePercent = (raw * 10.0).rounded() / 10.0
            }
        }

        var loadAvg = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loadAvg, 3)

        let info = ProcessInfo.processInfo
        return CPUStats(
            logicalCores: info.processorCount,
            activeCores: info.activeProcessorCount,
            usagePercent: usagePercent,
            loadAverage1m: loadCount >= 1 ? ((loadAvg[0] * 100).rounded() / 100) : nil,
            loadAverage5m: loadCount >= 2 ? ((loadAvg[1] * 100).rounded() / 100) : nil,
            loadAverage15m: loadCount >= 3 ? ((loadAvg[2] * 100).rounded() / 100) : nil
        )
    }

    // MARK: - Memory (Mach vm_statistics64)

    public static func collectMemoryStats() -> MemoryStats {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let pageSize = UInt64(max(1, sysconf(_SC_PAGESIZE)))

        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var vmStats = vm_statistics64_data_t()

        let result = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        let bytesPerGB = 1_073_741_824.0
        let totalGB = (Double(totalBytes) / bytesPerGB * 100).rounded() / 100

        guard result == KERN_SUCCESS, totalBytes > 0 else {
            return MemoryStats(totalGB: totalGB, usedGB: 0, freeGB: totalGB, usagePercent: 0)
        }

        let active = UInt64(vmStats.active_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize
        let usedBytes = min(totalBytes, active + wired + compressed)
        let freeBytes = totalBytes >= usedBytes ? (totalBytes - usedBytes) : 0

        let usedGB = (Double(usedBytes) / bytesPerGB * 100).rounded() / 100
        let freeGB = (Double(freeBytes) / bytesPerGB * 100).rounded() / 100
        let usagePercent = ((Double(usedBytes) / Double(totalBytes)) * 1000).rounded() / 10

        return MemoryStats(
            totalGB: totalGB,
            usedGB: usedGB,
            freeGB: freeGB,
            usagePercent: usagePercent
        )
    }

    // MARK: - Disk (Foundation Volume Resource Keys)

    public static func collectDiskStats() -> DiskStats? {
        let rootURL = URL(fileURLWithPath: "/")
        guard let values = try? rootURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]),
        let totalBytes = values.volumeTotalCapacity,
        totalBytes > 0 else {
            return nil
        }

        let availBytes: Int64 = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        let totalDouble = Double(totalBytes)
        let availDouble = max(0, Double(availBytes))
        let usedDouble = max(0, totalDouble - availDouble)
        let bytesPerGB = 1_000_000_000.0 // Apple decimal GB matching macOS Finder/Storage

        let totalGB = (totalDouble / bytesPerGB * 10).rounded() / 10
        let availableGB = (availDouble / bytesPerGB * 10).rounded() / 10
        let usedGB = (usedDouble / bytesPerGB * 10).rounded() / 10
        let usagePercent = ((usedDouble / totalDouble) * 1000).rounded() / 10

        return DiskStats(
            totalGB: totalGB,
            availableGB: availableGB,
            usedGB: usedGB,
            usagePercent: usagePercent
        )
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
