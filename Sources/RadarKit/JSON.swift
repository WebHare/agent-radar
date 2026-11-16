import Foundation

/// A decoded JSON object, as produced by JSONSerialization. Kept untyped because we read other programs'
/// undocumented state and only need a few fields.
public typealias JSONObject = [String: Any]

enum JSON {
  static func object(_ data: Data) -> JSONObject? {
    (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? JSONObject
  }

  static func object(contentsOf url: URL) -> JSONObject? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return object(data)
  }
}
