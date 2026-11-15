import Darwin
import Foundation

/// Why a child process stopped.
public enum ChildOutcome: Codable, Sendable, Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)
    case timedOut
    case cancelled
    case aborted(reason: String)

    public var isSuccess: Bool { self == .exited(code: 0) }
}

public struct ChildResult: Sendable {
    public var outcome: ChildOutcome
    public var stdout: String
    public var stderr: String
    public var wallSeconds: Double
    /// Kernel-tracked lifetime peak of the process's physical footprint
    /// (`ri_lifetime_max_phys_footprint`), sampled while it ran: the accounting
    /// Activity Monitor's "Memory" column uses. Measured on llama.cpp b12359:
    /// it **excludes memory-mapped model weights** (clean file-backed pages),
    /// so with the default mmap loading it is roughly compute + KV buffers only.
    public var peakFootprintBytes: UInt64?
    /// Peak resident set size: the max of `ri_resident_size` samples and the
    /// kernel's lifetime `ru_maxrss` from wait4. Unlike the footprint, this
    /// counts mapped model pages that are resident, so it reflects the weights
    /// in both mmap and non-mmap loading. Shared pages count fully.
    public var peakResidentBytes: UInt64?
    /// `ri_energy_nj` at the last sample. Kernel estimate; probably CPU only
    /// (unverified). Stored for research, never used for decisions.
    public var energyNanojoules: UInt64?
    public var userCPUSeconds: Double?
    public var systemCPUSeconds: Double?
}

/// Returns a reason to stop the child, or nil to keep going. Called a few
/// times per second while it runs.
public typealias ChildGuard = @Sendable () -> String?

public enum ChildProcess {
    /// Removes variables that silently change llama.cpp's behaviour
    /// (`LLAMA_ARG_*`), so results reflect only the flags we pass.
    public static func sanitizedEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        env.filter { !$0.key.hasPrefix("LLAMA_ARG_") }
    }

    /// Runs `argv` to completion, sampling memory every `sampleInterval`.
    /// Honors Swift task cancellation. Stopping sends SIGTERM to the child's
    /// whole process group, then SIGKILL after `killGrace` seconds, so helper
    /// processes it started cannot outlive it.
    ///
    /// Uses posix_spawn + waitpid rather than Foundation's Process: the child
    /// gets its own process group and default signal handling (a CLI that
    /// ignores SIGINT would otherwise pass that on), and reaping is under our
    /// control (Process.waitUntilExit was seen to hang after a kill).
    public static func run(_ argv: [String], timeout: TimeInterval, sampleInterval: TimeInterval = 0.25,
                           killGrace: TimeInterval = 3, environment: [String: String]? = nil,
                           guardCheck: ChildGuard? = nil, registry: ChildRegistry? = .shared) async throws -> ChildResult {
        precondition(!argv.isEmpty)
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let outURL = tmp.appendingPathComponent("zoomies-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("zoomies-\(UUID().uuidString).err")
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }

        let start = Date()
        // Files, not pipes: a chatty child can never block on a full pipe buffer.
        let pid = try spawn(argv, environment: environment ?? sanitizedEnvironment(), stdout: outURL.path, stderr: errURL.path)
        registry?.register(pid: pid, executable: argv[0])
        defer { registry?.unregister(pid: pid) }

        var peak: UInt64?
        var resident: UInt64?
        var energy: UInt64?
        var user: Double?
        var sys: Double?
        var stop: ChildOutcome?
        var status: Int32 = 0
        var ru = rusage()
        var reaped = false

        func sample() {
            guard let u = ResourceUsage.of(pid: pid) else { return }
            peak = max(peak ?? 0, u.lifetimeMaxFootprint)
            resident = max(resident ?? 0, u.residentBytes)
            energy = u.energyNanojoules
            user = u.userSeconds
            sys = u.systemSeconds
        }
        func poll() -> Bool {
            if !reaped && wait4(pid, &status, WNOHANG, &ru) == pid { reaped = true }
            return reaped
        }

        while true {
            sample()
            if poll() { break }
            if Task.isCancelled { stop = .cancelled }
            else if Date().timeIntervalSince(start) > timeout { stop = .timedOut }
            else if let reason = guardCheck?() { stop = .aborted(reason: reason) }
            if stop != nil { break }
            try? await Task.sleep(nanoseconds: UInt64(sampleInterval * 1e9))
        }
        if !reaped {
            kill(-pid, SIGTERM)
            let deadline = Date().addingTimeInterval(killGrace)
            while !poll() && Date() < deadline { usleep(50_000) }
            if !reaped {
                kill(-pid, SIGKILL)
                while wait4(pid, &status, 0, &ru) == -1 && errno == EINTR {}
                reaped = true
            }
        }
        kill(-pid, SIGKILL)  // anything left in the group (no-op when empty)

        // wait4's ru_maxrss (bytes on macOS) is the kernel's lifetime peak RSS;
        // it also covers runs too short to sample.
        let maxRSS = UInt64(max(0, ru.ru_maxrss))
        if maxRSS > 0 { resident = max(resident ?? 0, maxRSS) }
        let termSig = status & 0x7f
        let outcome: ChildOutcome = stop ?? (termSig == 0 ? .exited(code: (status >> 8) & 0xff) : .signaled(signal: termSig))
        return ChildResult(
            outcome: outcome,
            stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
            wallSeconds: Date().timeIntervalSince(start),
            peakFootprintBytes: peak,
            peakResidentBytes: resident,
            energyNanojoules: energy,
            userCPUSeconds: user ?? Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6,
            systemCPUSeconds: sys ?? Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
        )
    }

    static func spawn(_ argv: [String], environment: [String: String], stdout: String, stderr: String) throws -> pid_t {
        var fa = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&fa, 2, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setpgroup(&attr, 0)
        // CLOEXEC_DEFAULT: the child inherits only fds 0-2, never our database or files.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cArgs, cEnv)
        guard rc == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "could not start \(argv[0]): \(String(cString: strerror(rc)))"])
        }
        return pid
    }
}

struct ResourceUsage {
    var lifetimeMaxFootprint: UInt64
    var residentBytes: UInt64
    var energyNanojoules: UInt64
    var userSeconds: Double
    var systemSeconds: Double

    static func of(pid: pid_t) -> ResourceUsage? {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return nil }
        // ri_user_time / ri_system_time are in Mach absolute time units.
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let toSec = { (t: UInt64) in Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9 }
        return ResourceUsage(lifetimeMaxFootprint: info.ri_lifetime_max_phys_footprint,
                             residentBytes: info.ri_resident_size, energyNanojoules: info.ri_energy_nj,
                             userSeconds: toSec(info.ri_user_time), systemSeconds: toSec(info.ri_system_time))
    }
}

/// Crash recovery. Each running child is recorded as a small file; if Zoomies
/// dies mid-benchmark, the next start finds the file and stops the orphan,
/// but only if that pid still runs the same executable (pids get reused).
public final class ChildRegistry: @unchecked Sendable {
    public static let shared = ChildRegistry(directory: AppPaths.support.appendingPathComponent("children"))

    let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func register(pid: pid_t, executable: String) {
        lock.lock(); defer { lock.unlock() }
        try? Data(executable.utf8).write(to: directory.appendingPathComponent("\(pid)"))
    }

    func unregister(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(pid)"))
    }

    /// Stops orphaned children from a previous crash. Returns the pids stopped.
    @discardableResult
    public func reapOrphans() -> [pid_t] {
        lock.lock(); defer { lock.unlock() }
        var stopped: [pid_t] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files {
            defer { try? FileManager.default.removeItem(at: f) }
            guard let pid = pid_t(f.lastPathComponent),
                  let exe = try? String(contentsOf: f, encoding: .utf8),
                  let running = Self.executablePath(of: pid),
                  URL(fileURLWithPath: running).resolvingSymlinksInPath().path
                    == URL(fileURLWithPath: exe).resolvingSymlinksInPath().path else { continue }
            kill(pid, SIGTERM)
            stopped.append(pid)
        }
        return stopped
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/Zoomies (override with ZOOMIES_HOME).
    public static var support: URL {
        if let h = ProcessInfo.processInfo.environment["ZOOMIES_HOME"] { return URL(fileURLWithPath: h) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Zoomies")
    }

    public static var database: URL { support.appendingPathComponent("results.sqlite") }
}
