#if os(macOS)
import Darwin
import Foundation
import IOKit
import IOKit.ps
#if canImport(Metal)
import Metal
#endif

/// macOS probe. Uses only public, unprivileged interfaces: sysctl, Mach
/// host statistics, Metal, IOKit power sources and ProcessInfo. No root, no
/// private frameworks, no kernel extensions.
public struct MacHardwareProbe: HardwareProbe {
    public init() {}

    public func hardware() -> HardwareInfo {
        let pi = ProcessInfo.processInfo
        let v = pi.operatingSystemVersion
        return HardwareInfo(
            osName: "macOS",
            osVersion: Sysctl.string("kern.osproductversion") ?? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            osBuild: Sysctl.string("kern.osversion"),
            machineModel: Sysctl.string("hw.model"),
            cpuBrand: Sysctl.string("machdep.cpu.brand_string") ?? "unknown",
            physicalCores: Sysctl.int("hw.physicalcpu") ?? pi.activeProcessorCount,
            logicalCores: Sysctl.int("hw.logicalcpu") ?? pi.processorCount,
            clusters: Self.coreClusters(),
            memoryBytes: UInt64(Sysctl.int64("hw.memsize") ?? Int64(pi.physicalMemory)),
            gpus: Self.gpus()
        )
    }

    public func state() -> SystemState {
        SystemState(timestamp: Date(), memory: Self.memory(), thermal: Self.thermal(), power: Self.power(),
                    diskAvailableBytes: Self.diskAvailable())
    }

    // MARK: CPU

    /// Apple Silicon exposes its core clusters as `hw.perflevelN`, N=0 being the
    /// fastest. Intel Macs have none, so the list stays empty there.
    static func coreClusters() -> [CoreCluster] {
        guard let n = Sysctl.int("hw.nperflevels"), n > 0 else { return [] }
        return (0..<n).compactMap { i in
            guard let phys = Sysctl.int("hw.perflevel\(i).physicalcpu") else { return nil }
            return CoreCluster(
                name: Sysctl.string("hw.perflevel\(i).name") ?? "perflevel\(i)",
                physicalCores: phys,
                logicalCores: Sysctl.int("hw.perflevel\(i).logicalcpu") ?? phys,
                l2CacheBytes: Sysctl.int("hw.perflevel\(i).l2cachesize")
            )
        }
    }

    // MARK: GPU

    static func gpus() -> [GPUInfo] {
        #if canImport(Metal)
        return MTLCopyAllDevices().map { d in
            var families: [String] = []
            var candidates: [(MTLGPUFamily, String)] = [
                (.apple7, "apple7"), (.apple8, "apple8"), (.apple9, "apple9"), (.metal3, "metal3"),
            ]
            if #available(macOS 26.0, *) {
                candidates += [(.apple10, "apple10"), (.metal4, "metal4")]  // M5 generation
            }
            for (f, name) in candidates where d.supportsFamily(f) { families.append(name) }
            return GPUInfo(
                name: d.name,
                coreCount: gpuCoreCount(),
                unifiedMemory: d.hasUnifiedMemory,
                recommendedMaxWorkingSetBytes: d.recommendedMaxWorkingSetSize,
                maxBufferLengthBytes: UInt64(d.maxBufferLength),
                families: families
            )
        }
        #else
        return []
        #endif
    }

    /// The GPU core count is not part of Metal's API. The AGX accelerator's
    /// IORegistry entry carries it as `gpu-core-count` (the same value System
    /// Information shows). The key is undocumented, so the source says so.
    static func gpuCoreCount() -> Sourced<Int> {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return .unavailable("no AGXAccelerator in IORegistry") }
        defer { IOObjectRelease(service) }
        guard let prop = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue(), let n = prop as? Int else {
            return .unavailable("gpu-core-count not present")
        }
        return Sourced(n, source: "IORegistry AGXAccelerator gpu-core-count (undocumented key)")
    }

    // MARK: Memory

    static func memory() -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        func b(_ pages: natural_t) -> UInt64 { UInt64(pages) * page }
        func b(_ pages: UInt64) -> UInt64 { pages * page }
        return MemorySnapshot(
            totalBytes: UInt64(Sysctl.int64("hw.memsize") ?? 0),
            freeBytes: b(stats.free_count),
            activeBytes: b(stats.active_count),
            inactiveBytes: b(stats.inactive_count),
            wiredBytes: b(stats.wire_count),
            compressedBytes: b(stats.compressor_page_count),
            purgeableBytes: b(stats.purgeable_count),
            internalBytes: b(stats.internal_page_count),
            fileBackedBytes: b(stats.external_page_count),
            swapUsedBytes: swapUsed(),
            pressure: pressure()
        )
    }

    static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical
    /// (the same levels as DISPATCH_SOURCE_TYPE_MEMORYPRESSURE).
    static func pressure() -> MemoryPressureLevel {
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: .unavailable
        }
    }

    // MARK: Thermal / power / disk

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }

    static func power() -> PowerState {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerState(source: .unknown, batteryPercent: nil, isCharging: nil, lowPowerMode: lowPower)
        }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let source: PowerSource = switch type {
        case kIOPMACPowerKey: .ac
        case kIOPMBatteryPowerKey: .battery
        case kIOPMUPSPowerKey: .ups
        default: .unknown
        }
        var percent: Int?
        var charging: Bool?
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                if let cur = desc[kIOPSCurrentCapacityKey] as? Int, let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = cur * 100 / max
                }
                charging = desc[kIOPSIsChargingKey] as? Bool
            }
        }
        return PowerState(source: source, batteryPercent: percent, isCharging: charging, lowPowerMode: lowPower)
    }

    static func diskAvailable() -> UInt64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let n = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, n))
    }
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func int64(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4:
            var v: Int32 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return Int64(v)
        case 8:
            var v: Int64 = 0
            guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
            return v
        default:
            return nil
        }
    }

    static func int(_ name: String) -> Int? { int64(name).map(Int.init) }
}
#endif
