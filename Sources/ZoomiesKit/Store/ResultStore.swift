import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String { switch self { case .sqlite(let m): "SQLite: \(m)" } }
}

/// Persistent local history of benchmark runs.
///
/// Queryable columns for what you filter on (machine, model, runtime build,
/// config, test kind) and the complete report as JSON, so nothing measured
/// is ever lost to a schema that did not anticipate it.
public final class ResultStore {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = AppPaths.database) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.sqlite(lastError) }
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    private var lastError: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database" }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError) }
    }

    private func userVersion() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func migrate() throws {
        if userVersion() < 1 {
            try exec("""
            BEGIN;
            CREATE TABLE runs (
              id TEXT PRIMARY KEY,
              started_at REAL NOT NULL,
              finished_at REAL NOT NULL,
              tool_version TEXT NOT NULL,
              status TEXT NOT NULL,
              status_detail TEXT,
              hardware_fingerprint TEXT NOT NULL,
              os_version TEXT NOT NULL,
              cpu TEXT NOT NULL,
              model_path TEXT NOT NULL,
              model_fingerprint TEXT NOT NULL,
              model_sha256 TEXT,
              quantization TEXT,
              runtime TEXT NOT NULL,
              runtime_version TEXT,
              runtime_build INTEGER,
              runtime_commit TEXT,
              workload_json TEXT NOT NULL,
              report_json TEXT NOT NULL
            );
            CREATE TABLE trials (
              run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
              sequence INTEGER NOT NULL,
              round INTEGER NOT NULL,
              config_index INTEGER NOT NULL,
              config_json TEXT NOT NULL,
              command TEXT NOT NULL,
              outcome TEXT NOT NULL,
              error TEXT,
              wall_seconds REAL,
              peak_footprint_bytes INTEGER,
              thermal_before TEXT,
              thermal_after TEXT,
              power_source TEXT,
              PRIMARY KEY (run_id, sequence)
            );
            CREATE TABLE samples (
              run_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              kind TEXT NOT NULL,
              tokens INTEGER NOT NULL,
              depth INTEGER NOT NULL,
              repetition INTEGER NOT NULL,
              tokens_per_second REAL NOT NULL,
              FOREIGN KEY (run_id, sequence) REFERENCES trials(run_id, sequence) ON DELETE CASCADE
            );
            CREATE TABLE summaries (
              run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
              config_index INTEGER NOT NULL,
              config_label TEXT NOT NULL,
              kind TEXT NOT NULL,
              rounds INTEGER NOT NULL,
              mean REAL NOT NULL,
              stddev REAL NOT NULL,
              ci_low REAL,
              ci_high REAL,
              vs_baseline_percent REAL,
              vs_baseline_verdict TEXT,
              PRIMARY KEY (run_id, config_index, kind)
            );
            CREATE INDEX runs_by_model ON runs(hardware_fingerprint, model_fingerprint, started_at);
            PRAGMA user_version = 1;
            COMMIT;
            """)
        }
        if userVersion() < 2 {
            // Footprint excludes memory-mapped weights (measured on b12359); resident size includes them.
            try exec("""
            BEGIN;
            ALTER TABLE trials ADD COLUMN peak_resident_bytes INTEGER;
            PRAGMA user_version = 2;
            COMMIT;
            """)
        }
    }

    // MARK: Writing

    public func save(_ r: BenchmarkReport) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }

        try exec("BEGIN")
        do {
            try run("""
                INSERT INTO runs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [r.id.uuidString, r.startedAt.timeIntervalSince1970, r.finishedAt.timeIntervalSince1970, r.toolVersion,
                      r.status.rawValue, r.statusDetail, r.hardware.fingerprint, "\(r.hardware.osName) \(r.hardware.osVersion)",
                      r.hardware.cpuBrand, r.model.path, r.model.quickFingerprint, r.model.fullSHA256, r.model.quantization,
                      r.installation.runtimeID, r.installation.version, r.installation.buildNumber, r.installation.commit,
                      try json(r.plan.workload), try json(r)])
            for t in r.trials {
                try run("""
                    INSERT INTO trials (run_id, sequence, round, config_index, config_json, command, outcome, error,
                      wall_seconds, peak_footprint_bytes, thermal_before, thermal_after, power_source, peak_resident_bytes)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                        [r.id.uuidString, t.sequence, t.round, t.configIndex, try json(r.plan.configs[t.configIndex]),
                         t.command.joined(separator: " "), "\(t.outcome)", t.error, t.wallSeconds,
                         t.peakFootprintBytes.map { Int64(clamping: $0) }, t.stateBefore.thermal.rawValue,
                         t.stateAfter.thermal.rawValue, t.stateBefore.power.source.rawValue,
                         t.peakResidentBytes.map { Int64(clamping: $0) }])
                for m in t.measurements {
                    for (i, v) in m.samplesTPS.enumerated() {
                        try run("INSERT INTO samples VALUES (?,?,?,?,?,?,?)",
                                [r.id.uuidString, t.sequence, m.kind.rawValue, m.tokens, m.depth, i, v])
                    }
                }
            }
            for c in r.results {
                for k in c.kinds {
                    try run("INSERT INTO summaries VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                            [r.id.uuidString, c.configIndex, c.label, k.kind.rawValue, k.summary.n, k.summary.mean,
                             k.summary.stddev, k.summary.ciLow.isFinite ? k.summary.ciLow : nil,
                             k.summary.ciHigh.isFinite ? k.summary.ciHigh : nil,
                             k.vsBaseline?.relativePercent, k.vsBaseline?.verdict.rawValue])
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Reading

    public struct RunRow: Sendable {
        public var id: String
        public var startedAt: Date
        public var status: String
        public var modelPath: String
        public var quantization: String?
        public var runtimeBuild: Int?
    }

    public func recentRuns(limit: Int = 20) throws -> [RunRow] {
        var rows: [RunRow] = []
        try query("SELECT id, started_at, status, model_path, quantization, runtime_build FROM runs ORDER BY started_at DESC LIMIT ?",
                  [limit]) { s in
            rows.append(RunRow(id: Self.text(s, 0) ?? "", startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                               status: Self.text(s, 2) ?? "", modelPath: Self.text(s, 3) ?? "", quantization: Self.text(s, 4),
                               runtimeBuild: sqlite3_column_type(s, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 5))))
        }
        return rows
    }

    public func report(id: String) throws -> BenchmarkReport? {
        var json: String?
        try query("SELECT report_json FROM runs WHERE id = ?", [id]) { json = Self.text($0, 0) }
        guard let j = json else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        dec.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try dec.decode(BenchmarkReport.self, from: Data(j.utf8))
    }

    public func count(_ table: String) throws -> Int {
        precondition(["runs", "trials", "samples", "summaries"].contains(table))
        var n = 0
        try query("SELECT COUNT(*) FROM \(table)", []) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    // MARK: Plumbing

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            default: sqlite3_bind_text(stmt, idx, "\(a!)", -1, Self.transient)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Any?]) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(lastError) }
    }

    private func query(_ sql: String, _ args: [Any?], row: (OpaquePointer?) -> Void) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt) } else if rc == SQLITE_DONE { break } else { throw StoreError.sqlite(lastError) }
        }
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}
