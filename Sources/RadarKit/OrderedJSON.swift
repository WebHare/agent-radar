import Foundation

/// A JSON value that keeps the order of object members and the exact text of numbers, so Agent Radar can edit
/// the user's `settings.json` without reordering or reformatting what it doesn't change (apart from indentation).
public indirect enum OrderedJSON: Equatable {
  case object([(String, OrderedJSON)])
  case array([OrderedJSON])
  case string(String)
  /// The number as written, eg. `1.50`.
  case number(String)
  case bool(Bool)
  case null

  public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
    switch (lhs, rhs) {
    case let (.object(a), .object(b)): return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    case let (.array(a), .array(b)): return a == b
    case let (.string(a), .string(b)): return a == b
    case let (.number(a), .number(b)): return a == b
    case let (.bool(a), .bool(b)): return a == b
    case (.null, .null): return true
    default: return false
    }
  }

  public subscript(key: String) -> OrderedJSON? {
    get {
      guard case let .object(members) = self else { return nil }
      return members.first { $0.0 == key }?.1
    }
    set {
      guard case var .object(members) = self else { return }
      if let i = members.firstIndex(where: { $0.0 == key }) {
        if let newValue { members[i].1 = newValue } else { members.remove(at: i) }
      } else if let newValue {
        members.append((key, newValue))
      }
      self = .object(members)
    }
  }

  public var arrayValue: [OrderedJSON]? {
    if case let .array(items) = self { return items }
    return nil
  }

  public var stringValue: String? {
    if case let .string(s) = self { return s }
    return nil
  }

  public var objectMembers: [(String, OrderedJSON)]? {
    if case let .object(members) = self { return members }
    return nil
  }

  // MARK: Parsing

  public struct ParseError: Error, CustomStringConvertible {
    public var offset: Int
    public var description: String { "Invalid JSON at character \(offset)" }
  }

  public static func parse(_ text: String) throws -> OrderedJSON {
    var parser = Parser(scalars: Array(text.unicodeScalars))
    parser.skipWhitespace()
    let value = try parser.value()
    parser.skipWhitespace()
    guard parser.atEnd else { throw ParseError(offset: parser.pos) }
    return value
  }

  private struct Parser {
    let scalars: [Unicode.Scalar]
    var pos = 0

    var atEnd: Bool { pos >= scalars.count }
    var peek: Unicode.Scalar? { atEnd ? nil : scalars[pos] }

    mutating func skipWhitespace() {
      while let c = peek, c == " " || c == "\n" || c == "\r" || c == "\t" { pos += 1 }
    }

    mutating func expect(_ literal: String) throws {
      for c in literal.unicodeScalars {
        guard peek == c else { throw ParseError(offset: pos) }
        pos += 1
      }
    }

    mutating func value() throws -> OrderedJSON {
      switch peek {
      case "{": return try object()
      case "[": return try array()
      case "\"": return .string(try string())
      case "t": try expect("true"); return .bool(true)
      case "f": try expect("false"); return .bool(false)
      case "n": try expect("null"); return .null
      case let c? where c == "-" || ("0"..."9").contains(c): return .number(number())
      default: throw ParseError(offset: pos)
      }
    }

    mutating func object() throws -> OrderedJSON {
      pos += 1
      var members: [(String, OrderedJSON)] = []
      skipWhitespace()
      if peek == "}" { pos += 1; return .object(members) }
      while true {
        skipWhitespace()
        guard peek == "\"" else { throw ParseError(offset: pos) }
        let key = try string()
        skipWhitespace()
        try expect(":")
        skipWhitespace()
        members.append((key, try value()))
        skipWhitespace()
        if peek == "," { pos += 1; continue }
        try expect("}")
        return .object(members)
      }
    }

    mutating func array() throws -> OrderedJSON {
      pos += 1
      var items: [OrderedJSON] = []
      skipWhitespace()
      if peek == "]" { pos += 1; return .array(items) }
      while true {
        skipWhitespace()
        items.append(try value())
        skipWhitespace()
        if peek == "," { pos += 1; continue }
        try expect("]")
        return .array(items)
      }
    }

    mutating func string() throws -> String {
      pos += 1
      var result = String.UnicodeScalarView()
      while let c = peek {
        pos += 1
        switch c {
        case "\"":
          return String(result)
        case "\\":
          guard let e = peek else { throw ParseError(offset: pos) }
          pos += 1
          switch e {
          case "\"", "\\", "/": result.append(e)
          case "b": result.append("\u{08}")
          case "f": result.append("\u{0C}")
          case "n": result.append("\n")
          case "r": result.append("\r")
          case "t": result.append("\t")
          case "u":
            var code = try hex4()
            if (0xD800...0xDBFF).contains(code), peek == "\\" {
              pos += 1
              try expect("u")
              let low = try hex4()
              code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(code) else { throw ParseError(offset: pos) }
            result.append(scalar)
          default:
            throw ParseError(offset: pos)
          }
        default:
          result.append(c)
        }
      }
      throw ParseError(offset: pos)
    }

    mutating func hex4() throws -> UInt32 {
      guard pos + 4 <= scalars.count,
            let v = UInt32(String(String.UnicodeScalarView(scalars[pos..<pos + 4])), radix: 16) else {
        throw ParseError(offset: pos)
      }
      pos += 4
      return v
    }

    mutating func number() -> String {
      let start = pos
      while let c = peek, c == "-" || c == "+" || c == "." || c == "e" || c == "E" || ("0"..."9").contains(c) { pos += 1 }
      return String(String.UnicodeScalarView(scalars[start..<pos]))
    }
  }

  // MARK: Serializing

  /// Pretty-printed with two-space indentation, like Claude Code writes its settings.
  public func serialized() -> String {
    var out = ""
    write(to: &out, indent: "")
    return out + "\n"
  }

  private func write(to out: inout String, indent: String) {
    let inner = indent + "  "
    switch self {
    case let .object(members):
      if members.isEmpty { out += "{}"; return }
      out += "{\n"
      for (i, (key, value)) in members.enumerated() {
        out += inner + Self.quote(key) + ": "
        value.write(to: &out, indent: inner)
        out += i == members.count - 1 ? "\n" : ",\n"
      }
      out += indent + "}"
    case let .array(items):
      if items.isEmpty { out += "[]"; return }
      out += "[\n"
      for (i, item) in items.enumerated() {
        out += inner
        item.write(to: &out, indent: inner)
        out += i == items.count - 1 ? "\n" : ",\n"
      }
      out += indent + "]"
    case let .string(s): out += Self.quote(s)
    case let .number(n): out += n
    case let .bool(b): out += b ? "true" : "false"
    case .null: out += "null"
    }
  }

  static func quote(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
      switch c {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
      default: out.unicodeScalars.append(c)
      }
    }
    return out + "\""
  }
}
