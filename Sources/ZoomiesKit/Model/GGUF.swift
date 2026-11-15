import Foundation

public enum GGUFError: Error, Equatable, CustomStringConvertible {
    case notGGUF
    case unsupportedVersion(UInt32)
    case truncated(at: Int)
    case invalid(String)

    public var description: String {
        switch self {
        case .notGGUF: "not a GGUF file (bad magic)"
        case .unsupportedVersion(let v): "unsupported GGUF version \(v)"
        case .truncated(let at): "file ends early (needed data at byte \(at)); the download may be incomplete"
        case .invalid(let why): "invalid GGUF: \(why)"
        }
    }
}

/// A metadata value. Large arrays (tokenizer vocabularies) are not kept in
/// memory; only their element type and length are recorded.
public enum GGUFValue: Equatable, Sendable {
    case uint(UInt64)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case string(String)
    case array(elementType: UInt32, count: UInt64, values: [GGUFValue]?)

    public var intValue: Int? {
        switch self {
        case .uint(let v): v <= UInt64(Int.max) ? Int(v) : nil
        case .int(let v): Int(v)
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .float(let v): v
        case .uint(let v): Double(v)
        case .int(let v): Double(v)
        default: nil
        }
    }
}

public struct GGUFTensor: Equatable, Sendable {
    public var name: String
    public var dims: [UInt64]
    public var type: UInt32
    public var offset: UInt64
    /// Bytes on disk. From the ggml type table when known, otherwise from the
    /// distance to the next tensor (which includes alignment padding).
    public var byteSize: UInt64

    public var elementCount: UInt64 { dims.reduce(1, *) }
    public var typeName: String { GGMLType.name(type) }
}

/// Header, metadata and tensor table of a GGUF file. Tensor data is never read.
public struct GGUFFile: Sendable {
    public var version: UInt32
    public var metadata: [String: GGUFValue]
    public var metadataOrder: [String]
    public var tensors: [GGUFTensor]
    public var dataOffset: UInt64
    public var fileSize: UInt64

    /// Parses the header from `url`. Uses a memory-mapped read, so only the
    /// header pages are actually loaded even for a 70 GB model.
    public static func read(_ url: URL) throws -> GGUFFile {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> GGUFFile {
        var r = ByteReader(data: data)
        guard r.remaining >= 4, try r.bytes(4) == Data("GGUF".utf8) else { throw GGUFError.notGGUF }
        let version: UInt32 = try r.read()
        guard version == 2 || version == 3 else { throw GGUFError.unsupportedVersion(version) }
        let tensorCount: UInt64 = try r.read()
        let kvCount: UInt64 = try r.read()
        // Sanity limits: every entry takes at least a few bytes, so a count
        // larger than the file is a corrupt header, not a big model.
        guard tensorCount < UInt64(data.count), kvCount < UInt64(data.count) else {
            throw GGUFError.invalid("header claims \(tensorCount) tensors / \(kvCount) keys in a \(data.count)-byte file")
        }

        var metadata: [String: GGUFValue] = [:]
        var order: [String] = []
        for _ in 0..<kvCount {
            let key = try r.string()
            let type: UInt32 = try r.read()
            metadata[key] = try r.value(type: type, depth: 0)
            order.append(key)
        }

        var raw: [(String, [UInt64], UInt32, UInt64)] = []
        raw.reserveCapacity(Int(tensorCount))
        for _ in 0..<tensorCount {
            let name = try r.string()
            let nDims: UInt32 = try r.read()
            guard nDims <= 8 else { throw GGUFError.invalid("tensor \(name) has \(nDims) dimensions") }
            var dims: [UInt64] = []
            for _ in 0..<nDims { dims.append(try r.read()) }
            let type: UInt32 = try r.read()
            let offset: UInt64 = try r.read()
            raw.append((name, dims, type, offset))
        }

        let alignment = UInt64(metadata["general.alignment"]?.intValue ?? 32)
        guard alignment > 0, alignment & (alignment - 1) == 0 else { throw GGUFError.invalid("alignment \(alignment)") }
        let pos = UInt64(r.offset - data.startIndex)
        let dataOffset = (pos + alignment - 1) / alignment * alignment
        let fileSize = UInt64(data.count)

        // Fallback sizes from offset gaps.
        let sortedOffsets = raw.map(\.3).sorted()
        var nextOffset: [UInt64: UInt64] = [:]
        for (i, off) in sortedOffsets.enumerated() {
            nextOffset[off] = i + 1 < sortedOffsets.count ? sortedOffsets[i + 1] : (fileSize > dataOffset ? fileSize - dataOffset : 0)
        }
        var tensors: [GGUFTensor] = []
        tensors.reserveCapacity(raw.count)
        for (name, dims, type, offset) in raw {
            let elements = dims.reduce(1, *)
            let size = GGMLType.byteSize(type: type, elements: elements)
                ?? ((nextOffset[offset] ?? offset) >= offset ? (nextOffset[offset] ?? offset) - offset : 0)
            tensors.append(GGUFTensor(name: name, dims: dims, type: type, offset: offset, byteSize: size))
        }
        if let last = tensors.max(by: { $0.offset < $1.offset }), dataOffset + last.offset + last.byteSize > fileSize {
            throw GGUFError.truncated(at: Int(dataOffset + last.offset + last.byteSize))
        }
        return GGUFFile(version: version, metadata: metadata, metadataOrder: order, tensors: tensors,
                        dataOffset: dataOffset, fileSize: fileSize)
    }
}

struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func read<T: FixedWidthInteger>() throws -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { throw GGUFError.truncated(at: offset + n) }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset - data.startIndex, as: T.self) }
        offset += n
        return T(littleEndian: v)
    }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw GGUFError.truncated(at: offset + max(n, 0)) }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }

    mutating func skip(_ n: UInt64) throws {
        guard n <= UInt64(remaining) else { throw GGUFError.truncated(at: offset + Int(min(n, UInt64(Int.max / 2)))) }
        offset += Int(n)
    }

    mutating func string() throws -> String {
        let len: UInt64 = try read()
        guard len <= UInt64(remaining) else { throw GGUFError.truncated(at: offset + Int(min(len, UInt64(Int.max / 2)))) }
        let d = try bytes(Int(len))
        return String(decoding: d, as: UTF8.self)
    }

    /// GGUF value types: 0 u8, 1 i8, 2 u16, 3 i16, 4 u32, 5 i32, 6 f32, 7 bool,
    /// 8 string, 9 array, 10 u64, 11 i64, 12 f64.
    mutating func value(type: UInt32, depth: Int) throws -> GGUFValue {
        switch type {
        case 0: return .uint(UInt64(try read() as UInt8))
        case 1: return .int(Int64(try read() as Int8))
        case 2: return .uint(UInt64(try read() as UInt16))
        case 3: return .int(Int64(try read() as Int16))
        case 4: return .uint(UInt64(try read() as UInt32))
        case 5: return .int(Int64(try read() as Int32))
        case 6: return .float(Double(Float(bitPattern: try read() as UInt32)))
        case 7: return .bool((try read() as UInt8) != 0)
        case 8: return .string(try string())
        case 9:
            guard depth < 2 else { throw GGUFError.invalid("nested arrays deeper than 2") }
            let elementType: UInt32 = try read()
            let count: UInt64 = try read()
            guard count <= UInt64(remaining) else { throw GGUFError.truncated(at: offset + remaining + 1) }
            let keep = count <= 256
            var values: [GGUFValue] = []
            if let width = Self.fixedWidth(elementType), !keep {
                try skip(count * UInt64(width))  // fast path for big numeric arrays
                return .array(elementType: elementType, count: count, values: nil)
            }
            for _ in 0..<count {
                let v = try value(type: elementType, depth: depth + 1)
                if keep { values.append(v) }
            }
            return .array(elementType: elementType, count: count, values: keep ? values : nil)
        case 10: return .uint(try read() as UInt64)
        case 11: return .int(try read() as Int64)
        case 12: return .float(Double(bitPattern: try read() as UInt64))
        default: throw GGUFError.invalid("unknown metadata type \(type)")
        }
    }

    static func fixedWidth(_ type: UInt32) -> Int? {
        switch type {
        case 0, 1, 7: 1
        case 2, 3: 2
        case 4, 5, 6: 4
        case 10, 11, 12: 8
        default: nil
        }
    }
}

/// ggml tensor types: (name, elements per block, bytes per block). From
/// ggml/include/ggml.h and ggml/src/ggml.c `type_traits`. Unknown ids fall
/// back to offset gaps, so a new type never breaks parsing.
public enum GGMLType {
    static let table: [UInt32: (String, UInt64, UInt64)] = [
        0: ("F32", 1, 4), 1: ("F16", 1, 2), 2: ("Q4_0", 32, 18), 3: ("Q4_1", 32, 20),
        6: ("Q5_0", 32, 22), 7: ("Q5_1", 32, 24), 8: ("Q8_0", 32, 34), 9: ("Q8_1", 32, 36),
        10: ("Q2_K", 256, 84), 11: ("Q3_K", 256, 110), 12: ("Q4_K", 256, 144), 13: ("Q5_K", 256, 176),
        14: ("Q6_K", 256, 210), 15: ("Q8_K", 256, 292), 16: ("IQ2_XXS", 256, 66), 17: ("IQ2_XS", 256, 74),
        18: ("IQ3_XXS", 256, 98), 19: ("IQ1_S", 256, 50), 20: ("IQ4_NL", 32, 18), 21: ("IQ3_S", 256, 110),
        22: ("IQ2_S", 256, 82), 23: ("IQ4_XS", 256, 136), 24: ("I8", 1, 1), 25: ("I16", 1, 2),
        26: ("I32", 1, 4), 27: ("I64", 1, 8), 28: ("F64", 1, 8), 29: ("IQ1_M", 256, 56),
        30: ("BF16", 1, 2), 34: ("TQ1_0", 256, 54), 35: ("TQ2_0", 256, 66), 39: ("MXFP4", 32, 17),
    ]

    public static func name(_ type: UInt32) -> String { table[type]?.0 ?? "type\(type)" }

    public static func byteSize(type: UInt32, elements: UInt64) -> UInt64? {
        guard let (_, block, bytes) = table[type], elements % block == 0 else { return nil }
        return elements / block * bytes
    }

    /// Bytes per element for KV cache types accepted by llama.cpp's -ctk/-ctv.
    public static func kvBytesPerElement(_ name: String) -> Double? {
        switch name.lowercased() {
        case "f32": 4
        case "f16", "bf16": 2
        case "q8_0": 34.0 / 32
        case "q5_0": 22.0 / 32
        case "q5_1": 24.0 / 32
        case "q4_0", "iq4_nl": 18.0 / 32
        case "q4_1": 20.0 / 32
        default: nil
        }
    }
}

/// `general.file_type` (llama_ftype) to the familiar quantization label.
public enum LlamaFileType {
    static let names: [Int: String] = [
        0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1", 10: "Q2_K",
        11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M",
        18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S",
        25: "IQ4_NL", 26: "IQ3_S", 27: "IQ3_M", 28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M",
        32: "BF16", 36: "TQ1_0", 37: "TQ2_0", 38: "MXFP4_MOE",
    ]

    public static func name(_ ftype: Int) -> String { names[ftype] ?? "ftype\(ftype)" }
}
