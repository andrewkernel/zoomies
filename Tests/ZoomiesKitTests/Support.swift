import Foundation
@testable import ZoomiesKit

/// Builds GGUF v3 files in memory for parser tests.
struct GGUFBuilder {
    var kv: [(String, UInt32, Data)] = []
    var tensors: [(String, [UInt64], UInt32)] = []

    static func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func str(_ s: String) -> Data { le(UInt64(s.utf8.count)) + Data(s.utf8) }

    mutating func string(_ k: String, _ v: String) { kv.append((k, 8, Self.str(v))) }
    mutating func u32(_ k: String, _ v: UInt32) { kv.append((k, 4, Self.le(v))) }
    mutating func i32Array(_ k: String, _ v: [Int32]) {
        var d = Self.le(UInt32(5)) + Self.le(UInt64(v.count))
        for x in v { d += Self.le(x) }
        kv.append((k, 9, d))
    }
    mutating func stringArray(_ k: String, count: Int) {
        var d = Self.le(UInt32(8)) + Self.le(UInt64(count))
        for i in 0..<count { d += Self.str("tok\(i)") }
        kv.append((k, 9, d))
    }
    mutating func tensor(_ name: String, _ dims: [UInt64], type: UInt32) { tensors.append((name, dims, type)) }

    func build(truncateData: Bool = false) -> Data {
        var d = Data("GGUF".utf8) + Self.le(UInt32(3)) + Self.le(UInt64(tensors.count)) + Self.le(UInt64(kv.count))
        for (k, t, v) in kv { d += Self.str(k) + Self.le(t) + v }
        var offset: UInt64 = 0
        var sizes: [UInt64] = []
        for (name, dims, type) in tensors {
            d += Self.str(name) + Self.le(UInt32(dims.count))
            for x in dims { d += Self.le(x) }
            d += Self.le(type) + Self.le(offset)
            let size = GGMLType.byteSize(type: type, elements: dims.reduce(1, *))!
            sizes.append(size)
            offset += (size + 31) / 32 * 32
        }
        while d.count % 32 != 0 { d.append(0) }
        var total = offset
        if truncateData { total /= 2 }
        d += Data(count: Int(total))
        return d
    }

    /// A small Llama-shaped model: 2 layers, 8 heads / 2 KV heads, 64 dims.
    static func tinyLlama() -> GGUFBuilder {
        var b = GGUFBuilder()
        b.string("general.architecture", "llama")
        b.string("general.name", "Tiny Test Llama")
        b.u32("general.file_type", 15)  // Q4_K_M
        b.u32("llama.context_length", 4096)
        b.u32("llama.block_count", 2)
        b.u32("llama.embedding_length", 64)
        b.u32("llama.attention.head_count", 8)
        b.u32("llama.attention.head_count_kv", 2)
        b.stringArray("tokenizer.ggml.tokens", count: 1000)
        b.tensor("token_embd.weight", [64, 1000], type: 0)
        b.tensor("blk.0.attn_q.weight", [256, 64], type: 12)
        b.tensor("blk.0.ffn_down.weight", [256, 64], type: 14)
        return b
    }
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("zoomies-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func fixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
}

/// A stand-in for llama-bench: a shell script that answers --version/--help
/// and prints JSONL results. Throughput depends on -fa so comparisons have a
/// known right answer; a little pid-derived noise keeps CIs non-degenerate.
/// A fake llama-bench that behaves like the real one where Zoomies depends on it:
/// comma-separated values run as a cross product in one process, and every JSON
/// line reports the effective settings. Its performance model (deterministic,
/// plus a little per-process noise): fa=on gives +15% pp and +10% tg; ub=1024 or
/// more gives +6% pp when the prompt is at least that long; q8_0/q4_0 KV caches
/// cost 1%/3% tg; threads and poll change nothing.
func fakeLlamaBench(in dir: URL, sleepSeconds: Int = 0, fail: Bool = false, flashAttentionHelps: Bool = true,
                    memoryHogFlag: URL? = nil) -> URL {
    let help = fixture("llama-bench-b11347-help.txt").path
    let script = """
    #!/bin/sh
    case "$1" in
      --version) echo "version: 7100 (abc1234)"; echo "built with Apple clang for arm64"; exit 0;;
      --help) cat '\(help)'; exit 0;;
      --list-devices) echo "Available devices:"; echo "  MTL0: Apple M5 (12124 MiB, 12124 MiB free)"; exit 0;;
    esac
    \(sleepSeconds > 0 ? "sleep \(sleepSeconds)" : "")
    \(fail ? "echo 'llama_model_load: error loading model' >&2; exit 1" : "")
    FA=auto; T=2; UB=512; CTK=f16; CTV=f16; POLL=50; P=512; N=128; D=0; R=3; prev=""
    for a in "$@"; do
      case "$prev" in -fa) FA=$a;; -t) T=$a;; -ub) UB=$a;; -ctk) CTK=$a;; -ctv) CTV=$a;; --poll) POLL=$a;; -p) P=$a;; -n) N=$a;; -d) D=$a;; -r) R=$a;; esac
      prev=$a
    done
    echo "ggml_metal_device_init: testing tensor API for f16 support" >&2
    echo "some log line on stdout"
    NOISE=$(( $$ % 7 ))
    for fa in $(echo $FA | tr ',' ' '); do for t in $(echo $T | tr ',' ' '); do for ub in $(echo $UB | tr ',' ' '); do
    for ctk in $(echo $CTK | tr ',' ' '); do for ctv in $(echo $CTV | tr ',' ' '); do for poll in $(echo $POLL | tr ',' ' '); do
      case $fa in on) FAN=1;; off) FAN=0;; *) FAN=-1;; esac
      \(memoryHogFlag.map { "if [ \"$ub\" -ge 2048 ]; then touch '\($0.path)'; sleep 5; fi" } ?? "")
      if [ "$ctv" != "f16" ] && [ "$fa" = "off" ]; then echo "llama_init_from_model: V cache quantization requires flash_attn" >&2; exit 1; fi
      awk -v fa=$fa -v ub=$ub -v p=$P -v n=$N -v d=$D -v r=$R -v ctv=$ctv -v noise=$NOISE -v fan=$FAN \\
          -v t=$t -v ctk=$ctk -v poll=$poll 'BEGIN {
        pp = 1000 + noise; tg = 50 + noise / 10.0
        if (fa == "on" && \(flashAttentionHelps ? 1 : 0)) { pp *= 1.15; tg *= 1.10 }
        if (ub + 0 >= 1024 && p + 0 >= 1024) pp *= 1.06
        if (ctv == "q8_0") tg *= 0.99
        if (ctv == "q4_0") tg *= 0.97
        common = sprintf("\\"build_commit\\":\\"abc1234\\",\\"build_number\\":7100,\\"n_threads\\":%s,\\"n_ubatch\\":%s,\\"n_batch\\":2048,\\"flash_attn\\":%s,\\"type_k\\":\\"%s\\",\\"type_v\\":\\"%s\\",\\"poll\\":%s,\\"n_gpu_layers\\":-1,\\"n_depth\\":%s", t, ub, fan, ctk, ctv, poll, d)
        if (p > 0) {
          s = ""; for (i = 0; i < r; i++) s = s (i ? "," : "") sprintf("%.2f", pp + (i - 1) * 2)
          printf("{%s,\\"n_prompt\\":%s,\\"n_gen\\":0,\\"avg_ts\\":%.2f,\\"samples_ts\\":[%s]}\\n", common, p, pp, s)
        }
        if (n > 0) {
          s = ""; for (i = 0; i < r; i++) s = s (i ? "," : "") sprintf("%.3f", tg + (i - 1) * 0.05)
          printf("{%s,\\"n_prompt\\":0,\\"n_gen\\":%s,\\"avg_ts\\":%.3f,\\"samples_ts\\":[%s]}\\n", common, n, tg, s)
        }
      }'
    done; done; done; done; done; done
    """
    let url = dir.appendingPathComponent("llama-bench")
    try! script.write(to: url, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

struct FakeProbe: HardwareProbe {
    var hw = HardwareInfo(osName: "macOS", osVersion: "26.5", osBuild: "25F84", machineModel: "Mac17,2", cpuBrand: "Apple M5",
                          physicalCores: 10, logicalCores: 10,
                          clusters: [CoreCluster(name: "Super", physicalCores: 4, logicalCores: 4),
                                     CoreCluster(name: "Efficiency", physicalCores: 6, logicalCores: 6)],
                          memoryBytes: 16 << 30,
                          gpus: [GPUInfo(name: "Apple M5", coreCount: Sourced(10, source: "test"), unifiedMemory: true,
                                         recommendedMaxWorkingSetBytes: 12 << 30, maxBufferLengthBytes: nil, families: [])])
    var st = SystemState(timestamp: Date(), memory: MemorySnapshot(totalBytes: 16 << 30, freeBytes: 4 << 30, activeBytes: 4 << 30,
                                                                   inactiveBytes: 2 << 30, wiredBytes: 2 << 30, compressedBytes: 0,
                                                                   purgeableBytes: 0, internalBytes: 4 << 30, fileBackedBytes: 2 << 30,
                                                                   swapUsedBytes: 0, pressure: .normal),
                         thermal: .nominal, power: PowerState(source: .ac, batteryPercent: 100, isCharging: false, lowPowerMode: false),
                         diskAvailableBytes: 100 << 30)
    func hardware() -> HardwareInfo { hw }
    func state() -> SystemState { st }
}

func tinyModelFile() throws -> (URL, ModelInfo) {
    let url = tempDir().appendingPathComponent("tiny.gguf")
    try GGUFBuilder.tinyLlama().build().write(to: url)
    return (url, try ModelInspector.inspect(url))
}
