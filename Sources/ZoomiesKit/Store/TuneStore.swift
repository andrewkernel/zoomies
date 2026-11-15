import Foundation
import SQLite3

extension ResultStore {
    static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return enc
    }

    static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return dec
    }

    // MARK: Tune runs

    public func save(_ t: TuneReport) throws {
        let enc = Self.encoder()
        try run("""
            INSERT OR REPLACE INTO tune_runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, [t.id.uuidString, t.startedAt.timeIntervalSince1970, t.finishedAt.timeIntervalSince1970, t.hardware.fingerprint,
                  t.model.quickFingerprint, t.model.path, t.request.objective.rawValue, t.request.budget.rawValue,
                  t.decision.kind.rawValue, t.decision.headline,
                  String(decoding: try enc.encode(t.decision.config), as: UTF8.self),
                  String(decoding: try enc.encode(t), as: UTF8.self)])
    }

    public struct TuneRow: Sendable, Identifiable {
        public var id: String
        public var startedAt: Date
        public var modelPath: String
        public var objective: String
        public var budget: String
        public var decision: String
        public var headline: String
    }

    public func recentTunes(limit: Int = 50) throws -> [TuneRow] {
        var rows: [TuneRow] = []
        try query("SELECT id, started_at, model_path, objective, budget, decision, headline FROM tune_runs ORDER BY started_at DESC LIMIT ?",
                  [limit]) { s in
            rows.append(TuneRow(id: Self.text(s, 0) ?? "", startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                modelPath: Self.text(s, 2) ?? "", objective: Self.text(s, 3) ?? "", budget: Self.text(s, 4) ?? "",
                                decision: Self.text(s, 5) ?? "", headline: Self.text(s, 6) ?? ""))
        }
        return rows
    }

    public func tune(id: String) throws -> TuneReport? {
        var json: String?
        try query("SELECT report_json FROM tune_runs WHERE id = ?", [id]) { json = Self.text($0, 0) }
        return try json.map { try Self.decoder().decode(TuneReport.self, from: Data($0.utf8)) }
    }

    // MARK: Profiles

    public func save(_ p: TuningProfile) throws {
        try run("INSERT OR REPLACE INTO profiles VALUES (?,?,?,?,?,?)",
                [p.id.uuidString, p.createdAt.timeIntervalSince1970, p.modelFingerprint, p.hardwareFingerprint, p.name,
                 String(decoding: try Self.encoder().encode(p), as: UTF8.self)])
    }

    /// Profiles, newest first; filtered to one model/machine when given.
    public func profiles(modelFingerprint: String? = nil, hardwareFingerprint: String? = nil) throws -> [TuningProfile] {
        var sql = "SELECT profile_json FROM profiles"
        var args: [Any?] = []
        var conds: [String] = []
        if let m = modelFingerprint { conds.append("model_fingerprint = ?"); args.append(m) }
        if let h = hardwareFingerprint { conds.append("hardware_fingerprint = ?"); args.append(h) }
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        sql += " ORDER BY created_at DESC"
        var out: [TuningProfile] = []
        let dec = Self.decoder()
        try query(sql, args) { s in
            if let j = Self.text(s, 0), let p = try? dec.decode(TuningProfile.self, from: Data(j.utf8)) { out.append(p) }
        }
        return out
    }

    public func profile(id: String) throws -> TuningProfile? {
        var json: String?
        try query("SELECT profile_json FROM profiles WHERE id = ?", [id]) { json = Self.text($0, 0) }
        return try json.map { try Self.decoder().decode(TuningProfile.self, from: Data($0.utf8)) }
    }

    /// Makes a profile (or the runtime defaults, for nil) active for a model on a machine.
    public func activate(_ profileID: UUID?, modelFingerprint: String, hardwareFingerprint: String) throws {
        try run("INSERT INTO profile_activations (model_fingerprint, hardware_fingerprint, profile_id, activated_at) VALUES (?,?,?,?)",
                [modelFingerprint, hardwareFingerprint, profileID?.uuidString, Date().timeIntervalSince1970])
    }

    /// Activation history, newest first. nil entries mean "runtime defaults".
    public func activations(modelFingerprint: String, hardwareFingerprint: String) throws -> [UUID?] {
        var out: [UUID?] = []
        try query("""
            SELECT profile_id FROM profile_activations WHERE model_fingerprint = ? AND hardware_fingerprint = ? ORDER BY seq DESC
            """, [modelFingerprint, hardwareFingerprint]) { s in
            out.append(Self.text(s, 0).flatMap(UUID.init(uuidString:)))
        }
        return out
    }

    /// The active profile; nil means the runtime defaults (also when nothing was ever activated).
    public func activeProfile(modelFingerprint: String, hardwareFingerprint: String) throws -> TuningProfile? {
        guard let first = try activations(modelFingerprint: modelFingerprint, hardwareFingerprint: hardwareFingerprint).first,
              let id = first else { return nil }
        return try profile(id: id.uuidString)
    }

    /// Re-activates whatever was active before the current profile. Returns the
    /// newly active profile (nil = defaults). Rolling back twice returns to where you started.
    @discardableResult
    public func rollback(modelFingerprint: String, hardwareFingerprint: String) throws -> TuningProfile? {
        let history = try activations(modelFingerprint: modelFingerprint, hardwareFingerprint: hardwareFingerprint)
        guard let current = history.first else { return nil }
        let previous: UUID? = history.dropFirst().first { $0 != current } ?? nil
        try activate(previous, modelFingerprint: modelFingerprint, hardwareFingerprint: hardwareFingerprint)
        return try previous.flatMap { try profile(id: $0.uuidString) }
    }
}
