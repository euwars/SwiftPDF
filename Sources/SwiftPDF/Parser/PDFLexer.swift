import Foundation

enum PDFToken: Equatable {
  case integer(Int)
  case real(Double)
  case string(Data)
  case hexString(Data)
  case name(String)
  case boolTrue
  case boolFalse
  case null
  case arrayOpen // [
  case arrayClose // ]
  case dictOpen // <<
  case dictClose // >>
  case keyword(String) // obj, endobj, stream, endstream, R, etc.

  static func == (lhs: PDFToken, rhs: PDFToken) -> Bool {
    switch (lhs, rhs) {
    case let (.integer(a), .integer(b)): a == b
    case let (.real(a), .real(b)): a == b
    case let (.string(a), .string(b)): a == b
    case let (.hexString(a), .hexString(b)): a == b
    case let (.name(a), .name(b)): a == b
    case (.boolTrue, .boolTrue): true
    case (.boolFalse, .boolFalse): true
    case (.null, .null): true
    case (.arrayOpen, .arrayOpen): true
    case (.arrayClose, .arrayClose): true
    case (.dictOpen, .dictOpen): true
    case (.dictClose, .dictClose): true
    case let (.keyword(a), .keyword(b)): a == b
    default: false
    }
  }
}

struct PDFLexer {
  var reader: DataReader

  init(data: Data) {
    reader = DataReader(data: data)
  }

  init(data: Data, position: Int) {
    reader = DataReader(data: data)
    reader.position = position
  }

  private static let whitespace: Set<UInt8> = [0x00, 0x09, 0x0A, 0x0D, 0x0C, 0x20]
  private static let delimiters: Set<UInt8> = [
    UInt8(ascii: "("), UInt8(ascii: ")"),
    UInt8(ascii: "<"), UInt8(ascii: ">"),
    UInt8(ascii: "["), UInt8(ascii: "]"),
    UInt8(ascii: "{"), UInt8(ascii: "}"),
    UInt8(ascii: "/"), UInt8(ascii: "%"),
  ]

  mutating func nextToken() throws -> PDFToken? {
    reader.skipWhitespaceAndComments()
    guard !reader.isAtEnd else { return nil }

    let byte = reader.data[reader.position]

    switch byte {
    case UInt8(ascii: "["):
      reader.position += 1
      return .arrayOpen
    case UInt8(ascii: "]"):
      reader.position += 1
      return .arrayClose
    case UInt8(ascii: "<"):
      if reader.position + 1 < reader.data.count, reader.data[reader.position + 1] == UInt8(ascii: "<") {
        reader.position += 2
        return .dictOpen
      }
      return try readHexString()
    case UInt8(ascii: ">"):
      if reader.position + 1 < reader.data.count, reader.data[reader.position + 1] == UInt8(ascii: ">") {
        reader.position += 2
        return .dictClose
      }
      throw PDFError.parsingError("Unexpected '>' at position \(reader.position)")
    case UInt8(ascii: "("):
      return try readLiteralString()
    case UInt8(ascii: "/"):
      return try readName()
    case UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."),
         UInt8(ascii: "0") ... UInt8(ascii: "9"):
      return try readNumber()
    default:
      return try readKeywordOrBool()
    }
  }

  // MARK: - Token readers

  private mutating func readLiteralString() throws -> PDFToken {
    reader.position += 1 // skip '('
    var result = Data()
    var parenDepth = 1

    while !reader.isAtEnd {
      let byte = try reader.readByte()
      switch byte {
      case UInt8(ascii: "("):
        parenDepth += 1
        result.append(byte)
      case UInt8(ascii: ")"):
        parenDepth -= 1
        if parenDepth == 0 { return .string(result) }
        result.append(byte)
      case UInt8(ascii: "\\"):
        guard !reader.isAtEnd else { break }
        let escaped = try reader.readByte()
        switch escaped {
        case UInt8(ascii: "n"): result.append(0x0A)
        case UInt8(ascii: "r"): result.append(0x0D)
        case UInt8(ascii: "t"): result.append(0x09)
        case UInt8(ascii: "b"): result.append(0x08)
        case UInt8(ascii: "f"): result.append(0x0C)
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
          result.append(escaped)
        case UInt8(ascii: "0") ... UInt8(ascii: "7"):
          var octal = Int(escaped - UInt8(ascii: "0"))
          for _ in 0 ..< 2 {
            guard let next = reader.peekByte(),
                  next >= UInt8(ascii: "0"), next <= UInt8(ascii: "7") else { break }
            reader.position += 1
            octal = octal * 8 + Int(next - UInt8(ascii: "0"))
          }
          result.append(UInt8(octal & 0xFF))
        case 0x0A: // line continuation
          if reader.peekByte() == 0x0D { reader.position += 1 }
        case 0x0D:
          if reader.peekByte() == 0x0A { reader.position += 1 }
        default:
          result.append(escaped)
        }
      default:
        result.append(byte)
      }
    }
    throw PDFError.parsingError("Unterminated string literal")
  }

  private mutating func readHexString() throws -> PDFToken {
    reader.position += 1 // skip '<'
    var hexChars = [UInt8]()

    while !reader.isAtEnd {
      let byte = try reader.readByte()
      if byte == UInt8(ascii: ">") {
        break
      }
      if PDFLexer.whitespace.contains(byte) { continue }
      hexChars.append(byte)
    }

    // Pad odd-length hex strings with trailing 0
    if hexChars.count % 2 != 0 {
      hexChars.append(UInt8(ascii: "0"))
    }

    var result = Data()
    for i in stride(from: 0, to: hexChars.count, by: 2) {
      guard let high = hexValue(hexChars[i]),
            let low = hexValue(hexChars[i + 1])
      else {
        throw PDFError.parsingError("Invalid hex character in hex string")
      }
      result.append(high << 4 | low)
    }
    return .hexString(result)
  }

  private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
    case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
    default: nil
    }
  }

  private mutating func readName() throws -> PDFToken {
    reader.position += 1 // skip '/'
    var nameBytes = [UInt8]()

    while !reader.isAtEnd {
      let byte = reader.data[reader.position]
      if PDFLexer.whitespace.contains(byte) || PDFLexer.delimiters.contains(byte) {
        break
      }
      reader.position += 1
      if byte == UInt8(ascii: "#"), reader.position + 1 < reader.data.count {
        guard let high = hexValue(reader.data[reader.position]),
              let low = hexValue(reader.data[reader.position + 1])
        else {
          nameBytes.append(byte)
          continue
        }
        nameBytes.append(high << 4 | low)
        reader.position += 2
      } else {
        nameBytes.append(byte)
      }
    }
    return .name(String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1)!)
  }

  private mutating func readNumber() throws -> PDFToken {
    let start = reader.position
    var hasDecimal = false
    var isFirst = true

    while !reader.isAtEnd {
      let byte = reader.data[reader.position]
      if byte == UInt8(ascii: ".") {
        if hasDecimal { break }
        hasDecimal = true
        reader.position += 1
      } else if byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
        if !isFirst { break }
        reader.position += 1
      } else if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
        reader.position += 1
      } else {
        break
      }
      isFirst = false
    }

    let numData = reader.data[start ..< reader.position]
    guard let numStr = String(data: Data(numData), encoding: .ascii) else {
      throw PDFError.parsingError("Invalid number at position \(start)")
    }

    if hasDecimal {
      guard let value = Double(numStr) else {
        throw PDFError.parsingError("Invalid real number: \(numStr)")
      }
      return .real(value)
    } else {
      guard let value = Int(numStr) else {
        // Try as Double for very large numbers
        if let dv = Double(numStr) {
          return .real(dv)
        }
        throw PDFError.parsingError("Invalid integer: \(numStr)")
      }
      return .integer(value)
    }
  }

  private mutating func readKeywordOrBool() throws -> PDFToken {
    let start = reader.position
    while !reader.isAtEnd {
      let byte = reader.data[reader.position]
      if PDFLexer.whitespace.contains(byte) || PDFLexer.delimiters.contains(byte) {
        break
      }
      reader.position += 1
    }

    let wordData = reader.data[start ..< reader.position]
    guard let word = String(data: Data(wordData), encoding: .ascii) else {
      throw PDFError.parsingError("Invalid keyword at position \(start)")
    }

    switch word {
    case "true": return .boolTrue
    case "false": return .boolFalse
    case "null": return .null
    default: return .keyword(word)
    }
  }
}
