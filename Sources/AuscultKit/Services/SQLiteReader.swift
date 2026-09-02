import Foundation
import SQLite3

/// Minimal read-only SQLite reader.
///
/// Opened read-only and immutable: the powerlog we point this at is a copy of a
/// live database that iOS was writing when the sysdiagnose was taken, so it may
/// carry a hot journal. `immutable=1` tells SQLite not to attempt recovery or
/// locking, which is both correct for a snapshot and the only way to open it
/// without write access to the containing directory.
final class SQLiteReader {
    private var handle: OpaquePointer?

    init(path: String) throws {
        // The URI form is required for the query parameters to be honoured.
        let uri = "file:\(path)?immutable=1&mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError.cannotOpen(path, message)
        }
    }

    deinit { sqlite3_close(handle) }

    /// Column values for one row, keyed by column name. Everything is returned
    /// as `Double` or `String` because the powerlog stores numbers in columns
    /// with no declared affinity.
    struct Row {
        var values: [String: Value]

        enum Value {
            case text(String)
            case number(Double)
            case null

            var string: String? {
                switch self {
                case .text(let s): s
                case .number(let d): d == d.rounded() ? String(Int64(d)) : String(d)
                case .null: nil
                }
            }
            var double: Double? {
                switch self {
                case .number(let d): d
                case .text(let s): Double(s)
                case .null: nil
                }
            }
        }

        func string(_ column: String) -> String? { values[column]?.string }
        func double(_ column: String) -> Double? { values[column]?.double }
    }

    func query(_ sql: String, _ parameters: [String] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.badQuery(sql, String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, nil)
        }

        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let columnCount = sqlite3_column_count(statement)
            var values: [String: Row.Value] = [:]
            for column in 0..<columnCount {
                guard let namePointer = sqlite3_column_name(statement, column) else { continue }
                let name = String(cString: namePointer)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER, SQLITE_FLOAT:
                    values[name] = .number(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        values[name] = .text(String(cString: text))
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    /// Every table in the database.
    func tableNames() throws -> [String] {
        try query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .compactMap { $0.string("name") }
    }

    /// Column names for one table.
    func columnNames(of table: String) throws -> [String] {
        // PRAGMA can't take a bound parameter, so the identifier is quoted.
        try query("PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: ""))\")")
            .compactMap { $0.string("name") }
    }

    enum SQLiteError: LocalizedError {
        case cannotOpen(String, String)
        case badQuery(String, String)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let path, let message):
                "Could not open \((path as NSString).lastPathComponent): \(message)"
            case .badQuery(_, let message):
                "Query failed: \(message)"
            }
        }
    }
}
