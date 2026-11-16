import Foundation
import SQLite3

/// Reads values from VS Code's state.vscdb files (a SQLite table `ItemTable(key, value)`), read-only.
enum SQLiteReader {
  static func readItems(db: URL, keys: [String]) -> [String: Data] {
    guard !keys.isEmpty, FileManager.default.fileExists(atPath: db.path) else { return [:] }
    var handle: OpaquePointer?
    let uri = "file:\(db.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? db.path)?mode=ro"
    guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
      sqlite3_close(handle)
      return [:]
    }
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 250)

    let placeholders = keys.map { _ in "?" }.joined(separator: ",")
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))", -1, &stmt, nil) == SQLITE_OK else {
      return [:]
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, key) in keys.enumerated() {
      sqlite3_bind_text(stmt, Int32(i + 1), key, -1, transient)
    }

    var result: [String: Data] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let keyPtr = sqlite3_column_text(stmt, 0) else { continue }
      let key = String(cString: keyPtr)
      let len = Int(sqlite3_column_bytes(stmt, 1))
      if let blob = sqlite3_column_blob(stmt, 1), len > 0 {
        result[key] = Data(bytes: blob, count: len)
      }
    }
    return result
  }

  static func readJSONObjects(db: URL, keys: [String]) -> [String: JSONObject] {
    readItems(db: db, keys: keys).compactMapValues { JSON.object($0) }
  }
}
