import Foundation

struct DataReader {
  let data: Data
  var position: Int

  init(data: Data) {
    self.data = data
    position = 0
  }

  var isAtEnd: Bool {
    position >= data.count
  }

  var remaining: Int {
    max(0, data.count - position)
  }

  @discardableResult
  mutating func readByte() throws -> UInt8 {
    guard position < data.count else {
      throw PDFError.parsingError("Unexpected end of data at position \(position)")
    }
    let byte = data[position]
    position += 1
    return byte
  }

  func peekByte() -> UInt8? {
    guard position < data.count else { return nil }
    return data[position]
  }

  mutating func readBytes(_ count: Int) throws -> Data {
    guard position + count <= data.count else {
      throw PDFError.parsingError("Cannot read \(count) bytes at position \(position)")
    }
    let result = data[position ..< position + count]
    position += count
    return Data(result)
  }

  mutating func skip(_ count: Int) {
    position = min(position + count, data.count)
  }

  mutating func skipWhitespace() {
    while position < data.count {
      let byte = data[position]
      if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x00 || byte == 0x0C {
        position += 1
      } else {
        break
      }
    }
  }

  mutating func skipWhitespaceAndComments() {
    while position < data.count {
      let byte = data[position]
      if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x00 || byte == 0x0C {
        position += 1
      } else if byte == UInt8(ascii: "%") {
        // Skip comment until end of line
        position += 1
        while position < data.count {
          let c = data[position]
          position += 1
          if c == 0x0A || c == 0x0D { break }
        }
      } else {
        break
      }
    }
  }

  func subdata(from offset: Int, count: Int) -> Data? {
    guard offset >= 0, offset + count <= data.count else { return nil }
    return Data(data[offset ..< offset + count])
  }

  /// Search backwards from the end for a keyword
  func findLast(_ keyword: [UInt8], within lastBytes: Int = 1024) -> Int? {
    let searchStart = max(0, data.count - lastBytes)
    let searchRange = searchStart ..< data.count
    for i in stride(from: searchRange.upperBound - keyword.count, through: searchRange.lowerBound, by: -1) {
      var found = true
      for j in 0 ..< keyword.count {
        if data[i + j] != keyword[j] {
          found = false
          break
        }
      }
      if found { return i }
    }
    return nil
  }
}
