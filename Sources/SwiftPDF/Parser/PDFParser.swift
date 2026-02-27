import DequeModule
import Foundation

struct PDFParser {
  var lexer: PDFLexer
  private var tokenBuffer: Deque<PDFToken> = []

  init(data: Data) {
    lexer = PDFLexer(data: data)
  }

  init(data: Data, position: Int) {
    lexer = PDFLexer(data: data, position: position)
  }

  // MARK: - Token buffer for lookahead

  private mutating func peekToken(at offset: Int = 0) throws -> PDFToken? {
    while tokenBuffer.count <= offset {
      guard let token = try lexer.nextToken() else { return nil }
      tokenBuffer.append(token)
    }
    return tokenBuffer[offset]
  }

  @discardableResult
  private mutating func consumeToken() throws -> PDFToken? {
    if !tokenBuffer.isEmpty {
      return tokenBuffer.removeFirst()
    }
    return try lexer.nextToken()
  }

  // MARK: - Object parsing

  mutating func parseObject() throws -> PDFObject? {
    guard let token = try peekToken() else { return nil }

    switch token {
    case let .integer(num):
      // Lookahead: could be "int int R" (reference) or just an integer
      if let second = try peekToken(at: 1),
         case let .integer(gen) = second,
         let third = try peekToken(at: 2),
         case .keyword("R") = third
      {
        tokenBuffer.removeFirst(3)
        return .reference(PDFObjectIdentifier(objectNumber: num, generation: gen))
      }
      try consumeToken()
      return .integer(num)

    case let .real(num):
      try consumeToken()
      return .real(num)

    case let .string(data):
      try consumeToken()
      return .string(data)

    case let .hexString(data):
      try consumeToken()
      return .string(data)

    case let .name(name):
      try consumeToken()
      return .name(name)

    case .boolTrue:
      try consumeToken()
      return .bool(true)

    case .boolFalse:
      try consumeToken()
      return .bool(false)

    case .null:
      try consumeToken()
      return .null

    case .arrayOpen:
      return try parseArray()

    case .dictOpen:
      return try parseDictionary()

    case .keyword:
      return nil

    default:
      try consumeToken()
      return nil
    }
  }

  private mutating func parseArray() throws -> PDFObject {
    try consumeToken() // skip [
    var elements: [PDFObject] = []

    while true {
      guard let token = try peekToken() else {
        throw PDFError.parsingError("Unterminated array")
      }
      if case .arrayClose = token {
        try consumeToken()
        break
      }
      guard let obj = try parseObject() else {
        // skip unrecognized token
        try consumeToken()
        continue
      }
      elements.append(obj)
    }
    return .array(elements)
  }

  private mutating func parseDictionary() throws -> PDFObject {
    try consumeToken() // skip <<
    var dict: [String: PDFObject] = [:]

    while true {
      guard let token = try peekToken() else {
        throw PDFError.parsingError("Unterminated dictionary")
      }
      if case .dictClose = token {
        try consumeToken()
        break
      }
      guard case let .name(key) = token else {
        // Skip non-name tokens in dict context
        try consumeToken()
        continue
      }
      try consumeToken()

      guard let value = try parseObject() else {
        continue
      }
      dict[key] = value
    }
    return .dictionary(dict)
  }

  /// Parse a top-level indirect object definition: "N G obj ... endobj"
  mutating func parseIndirectObject() throws -> (PDFObjectIdentifier, PDFObject)? {
    guard let first = try peekToken(), case let .integer(objNum) = first,
          let second = try peekToken(at: 1), case let .integer(gen) = second,
          let third = try peekToken(at: 2), case .keyword("obj") = third
    else {
      return nil
    }
    tokenBuffer.removeFirst(3)

    let id = PDFObjectIdentifier(objectNumber: objNum, generation: gen)

    guard var object = try parseObject() else {
      throw PDFError.parsingError("Expected object value for \(id)")
    }

    // Check for stream
    if case let .dictionary(dict) = object {
      let savedPos = lexer.reader.position
      // Need to check raw bytes for "stream" keyword since it's followed by stream data
      if let token = try peekToken(), case .keyword("stream") = token {
        try consumeToken()
        // Stream data starts after the newline following "stream"
        var streamStart = lexer.reader.position
        // Skip \r\n or \n after "stream"
        if streamStart < lexer.reader.data.count, lexer.reader.data[streamStart] == 0x0D {
          streamStart += 1
        }
        if streamStart < lexer.reader.data.count, lexer.reader.data[streamStart] == 0x0A {
          streamStart += 1
        }

        // Get length
        let length: Int = if let lenObj = dict["Length"], case let .integer(len) = lenObj {
          len
        } else {
          // Length might be an indirect reference; find endstream marker
          findEndstream(from: streamStart)
        }

        let streamEnd = min(streamStart + length, lexer.reader.data.count)
        let streamData = Data(lexer.reader.data[streamStart ..< streamEnd])

        // Advance past stream data and endstream
        lexer.reader.position = streamEnd
        lexer.reader.skipWhitespaceAndComments()
        // Skip "endstream" keyword
        skipKeyword("endstream")

        object = .stream(dict, streamData)
      } else {
        lexer.reader.position = savedPos
        tokenBuffer.removeAll()
      }
    }

    // Skip "endobj"
    lexer.reader.skipWhitespaceAndComments()
    skipKeyword("endobj")

    return (id, object)
  }

  private mutating func skipKeyword(_ keyword: String) {
    let bytes = Array(keyword.utf8)
    let pos = lexer.reader.position
    if pos + bytes.count <= lexer.reader.data.count {
      var match = true
      for i in 0 ..< bytes.count {
        if lexer.reader.data[pos + i] != bytes[i] {
          match = false
          break
        }
      }
      if match {
        lexer.reader.position = pos + bytes.count
      }
    }
    tokenBuffer.removeAll()
  }

  private func findEndstream(from start: Int) -> Int {
    let marker = Array("endstream".utf8)
    let data = lexer.reader.data
    var i = start
    while i + marker.count <= data.count {
      var found = true
      for j in 0 ..< marker.count {
        if data[i + j] != marker[j] {
          found = false
          break
        }
      }
      if found {
        // Trim trailing whitespace before endstream
        var end = i
        while end > start, data[end - 1] == 0x0A || data[end - 1] == 0x0D {
          end -= 1
        }
        return end - start
      }
      i += 1
    }
    return data.count - start
  }
}
