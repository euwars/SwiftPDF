import Foundation

public indirect enum PDFObject: Sendable {
  case null
  case bool(Bool)
  case integer(Int)
  case real(Double)
  case string(Data)
  case name(String)
  case array([PDFObject])
  case dictionary([String: PDFObject])
  case stream([String: PDFObject], Data)
  case reference(PDFObjectIdentifier)

  // MARK: - Convenience accessors

  var intValue: Int? {
    if case let .integer(v) = self { return v }
    return nil
  }

  var realValue: Double? {
    switch self {
    case let .real(v): v
    case let .integer(v): Double(v)
    default: nil
    }
  }

  var nameValue: String? {
    if case let .name(v) = self { return v }
    return nil
  }

  var stringValue: Data? {
    if case let .string(v) = self { return v }
    return nil
  }

  var arrayValue: [PDFObject]? {
    if case let .array(v) = self { return v }
    return nil
  }

  var dictionaryValue: [String: PDFObject]? {
    switch self {
    case let .dictionary(v): v
    case let .stream(v, _): v
    default: nil
    }
  }

  var referenceValue: PDFObjectIdentifier? {
    if case let .reference(v) = self { return v }
    return nil
  }

  var boolValue: Bool? {
    if case let .bool(v) = self { return v }
    return nil
  }

  var streamData: Data? {
    if case let .stream(_, v) = self { return v }
    return nil
  }

  subscript(key: String) -> PDFObject? {
    dictionaryValue?[key]
  }
}
