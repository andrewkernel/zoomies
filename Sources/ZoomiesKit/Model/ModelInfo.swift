import Foundation

/// What Zoomies needs to know about a model, distilled from its GGUF header.
public struct ModelInfo: Codable, Sendable, Equatable {
    public var path: String
    public var fileName: String
    public var fileSize: UInt64
    public var ggufVersion: UInt32
    public var architecture: String?
    public var name: String?
    public var sizeLabel: String?
    public var quantization: String?
    public var parameterCount: UInt64
    public var weightBytes: UInt64
    /// Bytes per tensor type, e.g. ["Q4_K": ..., "Q6_K": ..., "F32": ...].
    public var tensorTypeBytes: [String: UInt64]
    public var trainedContextLength: Int?
    public var blockCount: Int?
    public var embeddingLength: Int?
    public var headCount: Int?
    public var headCountKV: Int?
    public var keyLength: Int?
    public var valueLength: Int?
    public var expertCount: Int?
    public var expertUsedCount: Int?
    public var slidingWindow: Int?
    /// Fast identity: SHA-256 over size + first and last 4 MiB. Cheap enough to
    /// compute on every run. See `fullSHA256` for the exact hash.
    public var quickFingerprint: String
    public var fullSHA256: String?

    public var isMoE: Bool { (expertCount ?? 0) > 1 }

    /// KV cache size for `contextTokens` with standard (full) attention:
    /// 2 (K and V) x layers x kv_heads x head_dim x context x bytes/element.
    /// Returns nil when the header lacks the fields. Sliding-window, hybrid and
    /// recurrent models use less, so treat this as an upper-bound estimate.
    public func kvCacheBytesEstimate(contextTokens: Int, typeK: String = "f16", typeV: String = "f16") -> UInt64? {
        guard let layers = blockCount, let heads = headCount, heads > 0, let embd = embeddingLength,
              let bk = GGMLType.kvBytesPerElement(typeK), let bv = GGMLType.kvBytesPerElement(typeV) else { return nil }
        let kvHeads = headCountKV ?? heads
        let kDim = keyLength ?? embd / heads
        let vDim = valueLength ?? embd / heads
        let perToken = Double(layers * kvHeads) * (Double(kDim) * bk + Double(vDim) * bv)
        return UInt64(perToken * Double(contextTokens))
    }
}

public enum ModelInspector {
    public static func inspect(_ url: URL, fullHash: Bool = false) throws -> ModelInfo {
        let g = try GGUFFile.read(url)
        return try summarize(g, url: url, fullHash: fullHash)
    }

    static func summarize(_ g: GGUFFile, url: URL, fullHash: Bool) throws -> ModelInfo {
        let md = g.metadata
        let arch = md["general.architecture"]?.stringValue
        func a(_ key: String) -> GGUFValue? { arch.flatMap { md["\($0).\(key)"] } }
        /// Some architectures store per-layer arrays (e.g. head_count_kv); the
        /// largest layer is what bounds memory.
        func int(_ v: GGUFValue?) -> Int? {
            guard let v else { return nil }
            if case .array(_, _, let values?) = v { return values.compactMap(\.intValue).max() }
            return v.intValue
        }
        var byType: [String: UInt64] = [:]
        var params: UInt64 = 0
        var weights: UInt64 = 0
        for t in g.tensors {
            byType[t.typeName, default: 0] += t.byteSize
            params += t.elementCount
            weights += t.byteSize
        }
        let ftype = md["general.file_type"]?.intValue
        return ModelInfo(
            path: url.path,
            fileName: url.lastPathComponent,
            fileSize: g.fileSize,
            ggufVersion: g.version,
            architecture: arch,
            name: md["general.name"]?.stringValue,
            sizeLabel: md["general.size_label"]?.stringValue,
            quantization: ftype.map(LlamaFileType.name) ?? dominantType(byType),
            parameterCount: params,
            weightBytes: weights,
            tensorTypeBytes: byType,
            trainedContextLength: int(a("context_length")),
            blockCount: int(a("block_count")),
            embeddingLength: int(a("embedding_length")),
            headCount: int(a("attention.head_count")),
            headCountKV: int(a("attention.head_count_kv")),
            keyLength: int(a("attention.key_length")),
            valueLength: int(a("attention.value_length")),
            expertCount: int(a("expert_count")),
            expertUsedCount: int(a("expert_used_count")),
            slidingWindow: int(a("attention.sliding_window")),
            quickFingerprint: try quickFingerprint(url, size: g.fileSize),
            fullSHA256: fullHash ? try SHA256Hex.file(at: url) : nil
        )
    }

    static func dominantType(_ byType: [String: UInt64]) -> String? {
        byType.filter { $0.key != "F32" }.max { $0.value < $1.value }?.key
    }

    /// SHA-256 of (size, first 4 MiB, last 4 MiB). Distinguishes different
    /// quantizations and fine-tunes in practice and costs milliseconds; the
    /// full hash is available when exact identity matters.
    public static func quickFingerprint(_ url: URL, size: UInt64) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let chunk = 4 << 20
        var d = Data("\(size)|".utf8)
        d.append(try h.read(upToCount: chunk) ?? Data())
        if size > UInt64(2 * chunk) {
            try h.seek(toOffset: size - UInt64(chunk))
            d.append(try h.read(upToCount: chunk) ?? Data())
        }
        return String(SHA256Hex.digest(d).prefix(32))
    }
}
