import Foundation

/// A metric value together with where it came from. Probes never invent a
/// value: when a source is unavailable the value is nil and `source` says why.
public struct Sourced<T: Codable & Sendable>: Codable, Sendable {
    public var value: T?
    public var source: String

    public init(_ value: T?, source: String) {
        self.value = value
        self.source = source
    }

    public static func unavailable(_ why: String) -> Sourced<T> { Sourced(nil, source: "unavailable: \(why)") }
}

extension Sourced: Equatable where T: Equatable {}

/// One cluster of identical CPU cores (on Apple Silicon: a "perflevel").
public struct CoreCluster: Codable, Sendable, Equatable {
    public var name: String
    public var physicalCores: Int
    public var logicalCores: Int
    public var l2CacheBytes: Int?

    public init(name: String, physicalCores: Int, logicalCores: Int, l2CacheBytes: Int? = nil) {
        self.name = name
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.l2CacheBytes = l2CacheBytes
    }
}

public struct GPUInfo: Codable, Sendable, Equatable {
    public var name: String
    public var coreCount: Sourced<Int>
    public var unifiedMemory: Bool
    /// Metal's `recommendedMaxWorkingSetSize`: how much memory the GPU can use
    /// before performance suffers. On Apple Silicon this is a fraction of RAM.
    public var recommendedMaxWorkingSetBytes: UInt64?
    public var maxBufferLengthBytes: UInt64?
    public var families: [String]

    public init(name: String, coreCount: Sourced<Int>, unifiedMemory: Bool,
                recommendedMaxWorkingSetBytes: UInt64?, maxBufferLengthBytes: UInt64?, families: [String]) {
        self.name = name
        self.coreCount = coreCount
        self.unifiedMemory = unifiedMemory
        self.recommendedMaxWorkingSetBytes = recommendedMaxWorkingSetBytes
        self.maxBufferLengthBytes = maxBufferLengthBytes
        self.families = families
    }
}

/// Static facts about the machine. These do not change between runs, so
/// they make up the hardware fingerprint.
public struct HardwareInfo: Codable, Sendable, Equatable {
    public var osName: String
    public var osVersion: String
    public var osBuild: String?
    public var machineModel: String?
    public var cpuBrand: String
    public var physicalCores: Int
    public var logicalCores: Int
    /// Core clusters ordered fastest first. Empty when the OS does not expose them.
    public var clusters: [CoreCluster]
    public var memoryBytes: UInt64
    public var gpus: [GPUInfo]

    public init(osName: String, osVersion: String, osBuild: String?, machineModel: String?, cpuBrand: String,
                physicalCores: Int, logicalCores: Int, clusters: [CoreCluster], memoryBytes: UInt64, gpus: [GPUInfo]) {
        self.osName = osName
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.machineModel = machineModel
        self.cpuBrand = cpuBrand
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.clusters = clusters
        self.memoryBytes = memoryBytes
        self.gpus = gpus
    }

    /// Cores in the fastest cluster, or every physical core when clusters are unknown.
    public var performanceCores: Int { clusters.first?.physicalCores ?? physicalCores }
    public var efficiencyCores: Int { clusters.dropFirst().reduce(0) { $0 + $1.physicalCores } }

    /// Stable id for "the same machine". The OS version is left out on purpose
    /// (it is stored with every run instead), so an OS update keeps history comparable
    /// while still being visible.
    public var fingerprint: String {
        let parts: [String] = [
            osName, machineModel ?? "", cpuBrand, "\(memoryBytes)",
            clusters.map { "\($0.name):\($0.physicalCores)/\($0.logicalCores)" }.joined(separator: ","),
            gpus.map { "\($0.name):\($0.coreCount.value.map(String.init) ?? "?")" }.joined(separator: ","),
        ]
        return String(SHA256Hex.digest(Data(parts.joined(separator: "|").utf8)).prefix(16))
    }
}

public enum ThermalLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical, unavailable

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .unavailable: -1
        }
    }

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rank < b.rank }
}

public enum MemoryPressureLevel: String, Codable, Sendable, Comparable {
    case normal, warning, critical, unavailable

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        case .unavailable: -1
        }
    }

    public static func < (a: MemoryPressureLevel, b: MemoryPressureLevel) -> Bool { a.rank < b.rank }
}

public struct MemorySnapshot: Codable, Sendable, Equatable {
    public var totalBytes: UInt64
    public var freeBytes: UInt64
    public var activeBytes: UInt64
    public var inactiveBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var purgeableBytes: UInt64
    /// Anonymous ("app") memory, the part that cannot simply be dropped.
    public var internalBytes: UInt64
    /// File-backed pages (cached files, mmapped models).
    public var fileBackedBytes: UInt64
    public var swapUsedBytes: UInt64?
    public var pressure: MemoryPressureLevel

    public init(totalBytes: UInt64, freeBytes: UInt64, activeBytes: UInt64, inactiveBytes: UInt64, wiredBytes: UInt64,
                compressedBytes: UInt64, purgeableBytes: UInt64, internalBytes: UInt64, fileBackedBytes: UInt64,
                swapUsedBytes: UInt64?, pressure: MemoryPressureLevel) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.purgeableBytes = purgeableBytes
        self.internalBytes = internalBytes
        self.fileBackedBytes = fileBackedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    /// Estimate of memory a new workload can get without forcing compression
    /// or swap: total minus app memory, wired memory and the compressor.
    /// This follows Activity Monitor's "Memory Used" breakdown. It is an
    /// estimate: macOS decides at runtime what it evicts.
    public var availableEstimateBytes: UInt64 {
        let app = internalBytes > purgeableBytes ? internalBytes - purgeableBytes : 0
        let used = app + wiredBytes + compressedBytes
        return totalBytes > used ? totalBytes - used : 0
    }
}

public enum PowerSource: String, Codable, Sendable {
    case ac, battery, ups, unknown
}

public struct PowerState: Codable, Sendable, Equatable {
    public var source: PowerSource
    public var batteryPercent: Int?
    public var isCharging: Bool?
    public var lowPowerMode: Bool

    public init(source: PowerSource, batteryPercent: Int?, isCharging: Bool?, lowPowerMode: Bool) {
        self.source = source
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
    }
}

/// Things that change from minute to minute. Captured before and after every run.
public struct SystemState: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var memory: MemorySnapshot?
    public var thermal: ThermalLevel
    public var power: PowerState
    public var diskAvailableBytes: UInt64?

    public init(timestamp: Date, memory: MemorySnapshot?, thermal: ThermalLevel, power: PowerState, diskAvailableBytes: UInt64?) {
        self.timestamp = timestamp
        self.memory = memory
        self.thermal = thermal
        self.power = power
        self.diskAvailableBytes = diskAvailableBytes
    }
}

/// Platform-specific probes sit behind this protocol so the optimizer and
/// benchmark runner never depend on macOS APIs directly.
public protocol HardwareProbe: Sendable {
    func hardware() -> HardwareInfo
    func state() -> SystemState
}

public enum HardwareProbes {
    /// The probe for the platform this binary runs on.
    public static func current() -> HardwareProbe {
        #if os(macOS)
        return MacHardwareProbe()
        #else
        return GenericHardwareProbe()
        #endif
    }
}

/// Fallback for platforms without a dedicated probe yet: only what Foundation
/// can tell portably. Everything else is reported as unavailable.
public struct GenericHardwareProbe: HardwareProbe {
    public init() {}

    public func hardware() -> HardwareInfo {
        let pi = ProcessInfo.processInfo
        let v = pi.operatingSystemVersion
        return HardwareInfo(osName: pi.operatingSystemVersionString, osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                            osBuild: nil, machineModel: nil, cpuBrand: "unknown", physicalCores: pi.activeProcessorCount,
                            logicalCores: pi.processorCount, clusters: [], memoryBytes: pi.physicalMemory, gpus: [])
    }

    public func state() -> SystemState {
        SystemState(timestamp: Date(), memory: nil, thermal: .unavailable,
                    power: PowerState(source: .unknown, batteryPercent: nil, isCharging: nil, lowPowerMode: false),
                    diskAvailableBytes: nil)
    }
}
