import Foundation

struct PDFXRefParser {
  let data: Data
  /// Offset of %PDF- header; used to adjust xref byte offsets when junk precedes the header
  let contentOffset: Int

  init(data: Data, contentOffset: Int = 0) {
    self.data = data
    self.contentOffset = contentOffset
  }

  /// Find the startxref offset from the end of the PDF.
  /// Searches further back than the spec requires (handles junk appended after %%EOF).
  func findStartXRef() throws -> Int {
    let keyword = Array("startxref".utf8)
    // Search the entire file if needed (some files have lots of appended data)
    let reader = DataReader(data: data)
    guard let pos = reader.findLast(keyword, within: data.count) else {
      throw PDFError.xrefError("Cannot find startxref")
    }

    return try readStartXRefOffset(at: pos + keyword.count)
  }

  /// Read the integer offset value after a startxref keyword position
  private func readStartXRefOffset(at position: Int) throws -> Int {
    var r = DataReader(data: data)
    r.position = position
    r.skipWhitespace()

    let start = r.position
    while !r.isAtEnd {
      let byte = r.data[r.position]
      if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
        r.position += 1
      } else {
        break
      }
    }

    let numData = Data(r.data[start ..< r.position])
    guard let numStr = String(data: numData, encoding: .ascii),
          let offset = Int(numStr)
    else {
      throw PDFError.xrefError("Invalid startxref offset")
    }
    return offset
  }

  /// Quick search for other startxref offsets besides the primary one.
  /// For linearized PDFs, checks the first portion of the file for an additional startxref.
  private func findOtherStartXRefs(excluding primaryOffset: Int) -> [Int] {
    let keyword = Array("startxref".utf8)
    var results: [Int] = []
    // Linearized PDFs have a startxref near the beginning of the file.
    // Scan the first 64KB and the region around the primary offset.
    let scanLimit = min(data.count, 65536)
    var i = 0
    while i + keyword.count <= scanLimit {
      var found = true
      for j in 0 ..< keyword.count {
        if data[i + j] != keyword[j] { found = false; break }
      }
      if found {
        if let offset = try? readStartXRefOffset(at: i + keyword.count),
           offset != primaryOffset
        {
          results.append(offset)
        }
        i += keyword.count
      } else {
        i += 1
      }
    }
    return results
  }

  /// Find all startxref positions — searches first 64KB and last 64KB of the file
  /// to avoid scanning huge files byte-by-byte.
  private func findAllStartXRefs() -> [Int] {
    let keyword = Array("startxref".utf8)
    var positions: [Int] = []
    let regions: [(Int, Int)] = [
      (0, min(data.count, 65536)),
      (max(0, data.count - 65536), data.count),
    ]
    for (regionStart, regionEnd) in regions {
      var i = regionStart
      while i + keyword.count <= regionEnd {
        var found = true
        for j in 0 ..< keyword.count {
          if data[i + j] != keyword[j] { found = false; break }
        }
        if found {
          if let offset = try? readStartXRefOffset(at: i + keyword.count) {
            if !positions.contains(offset) {
              positions.append(offset)
            }
          }
          i += keyword.count
        } else {
          i += 1
        }
      }
    }
    return positions
  }

  /// Parse the full xref table (following /Prev chains) and trailer.
  /// Strategy:
  ///   1. Try the last startxref and follow /Prev chains
  ///   2. For linearized PDFs, try all startxref positions and merge
  ///   3. Fall back to brute-force scanning for xref keywords
  func parse() throws -> (PDFXRefTable, PDFTrailer) {
    // Try the primary (last) startxref first — this handles the vast majority of PDFs.
    // The /Prev chain in parseFromStartXRef handles incremental updates.
    if let primaryOffset = try? findStartXRef() {
      if let result = try? parseFromStartXRef(primaryOffset) {
        var table = result.0
        let trailer = result.1

        // For linearized PDFs, the primary startxref points to the first-page xref,
        // and the main xref is elsewhere without a /Prev link. Scan for additional
        // startxref offsets only if we detect this situation (multiple startxrefs exist).
        let otherStartXRefs = findOtherStartXRefs(excluding: primaryOffset)
        for offset in otherStartXRefs {
          _ = parseXRefAt(offset + contentOffset, into: &table)
        }

        return (table, trailer)
      }
    }

    // Primary startxref failed — try scanning for all startxref positions.
    let allStartXRefs = findAllStartXRefs()
    for offset in allStartXRefs.reversed() {
      if let result = try? parseFromStartXRef(offset) {
        if result.1.root != nil {
          return result
        }
      }
    }

    // Brute-force: find all "xref" keywords and try to parse them
    if let result = try? bruteForceXRefScan() {
      return result
    }

    throw PDFError.xrefError("Cannot parse xref table")
  }

  /// Try to parse a single xref section at the given offset, adding entries to the table
  private func parseXRefAt(_ offset: Int, into table: inout PDFXRefTable) -> PDFTrailer? {
    let adjusted = adjustedXRefOffset(offset)
    if isTraditionalXRef(at: offset) {
      return try? parseTraditionalXRef(at: adjusted, into: &table)
    } else {
      return try? parseXRefStream(at: adjusted, into: &table)
    }
  }

  private func parseFromStartXRef(_ startXRef: Int) throws -> (PDFXRefTable, PDFTrailer) {
    var xrefTable = PDFXRefTable()
    var trailer: PDFTrailer?

    var xrefOffset = startXRef + contentOffset

    var visited = Set<Int>()
    while true {
      guard xrefOffset >= 0, xrefOffset < data.count else {
        throw PDFError.xrefError("Invalid xref offset: \(xrefOffset)")
      }
      guard !visited.contains(xrefOffset) else { break }
      visited.insert(xrefOffset)

      let adjustedOffset = adjustedXRefOffset(xrefOffset)

      let currentTrailer: PDFTrailer = if isTraditionalXRef(at: xrefOffset) {
        try parseTraditionalXRef(at: adjustedOffset, into: &xrefTable)
      } else {
        try parseXRefStream(at: adjustedOffset, into: &xrefTable)
      }

      if trailer == nil {
        trailer = currentTrailer
      }

      if let prev = currentTrailer.prev {
        xrefOffset = prev + contentOffset
      } else {
        break
      }
    }

    guard let finalTrailer = trailer else {
      throw PDFError.xrefError("No trailer found")
    }
    return (xrefTable, finalTrailer)
  }

  /// Scan the entire file for "xref" keywords and try to build a complete xref table
  private func bruteForceXRefScan() throws -> (PDFXRefTable, PDFTrailer) {
    let xrefPositions = findAllXRefKeywords()
    var bestTrailer: PDFTrailer?
    var mergedTable = PDFXRefTable()

    // Parse all xref sections we can find, from last to first
    for pos in xrefPositions.reversed() {
      if let trailer = try? parseTraditionalXRef(at: pos, into: &mergedTable) {
        if bestTrailer == nil || (trailer.root != nil && bestTrailer?.root == nil) {
          bestTrailer = trailer
        }
      }
    }

    guard let trailer = bestTrailer, trailer.root != nil else {
      throw PDFError.xrefError("No valid xref found via brute-force scan")
    }
    return (mergedTable, trailer)
  }

  /// Find byte offsets of "xref" keywords (not "startxref") — searches first/last 64KB only
  private func findAllXRefKeywords() -> [Int] {
    let keyword = Array("xref".utf8)
    let start_kw = Array("startxref".utf8)
    var positions: [Int] = []
    let regions: [(Int, Int)] = [
      (0, min(data.count, 65536)),
      (max(0, data.count - 65536), data.count),
    ]
    for (regionStart, regionEnd) in regions {
      var i = regionStart
      while i + keyword.count <= regionEnd {
        var match = true
        for j in 0 ..< keyword.count {
          if data[i + j] != keyword[j] { match = false; break }
        }
        if match {
          let isStartXRef = i >= 5 && {
            var m = true
            for j in 0 ..< start_kw.count {
              if data[i - 5 + j] != start_kw[j] { m = false; break }
            }
            return m
          }()
          if !isStartXRef, !positions.contains(i) {
            positions.append(i)
          }
          i += keyword.count
        } else {
          i += 1
        }
      }
    }
    return positions
  }

  /// Check if offset points to a traditional "xref" table (with whitespace skipping)
  private func isTraditionalXRef(at offset: Int) -> Bool {
    let adjustedOffset = skipWhitespaceAt(offset)
    let keyword = Array("xref".utf8)
    guard adjustedOffset + keyword.count <= data.count else { return false }
    for i in 0 ..< keyword.count {
      if data[adjustedOffset + i] != keyword[i] { return false }
    }
    return true
  }

  /// Return the adjusted offset after skipping whitespace
  private func adjustedXRefOffset(_ offset: Int) -> Int {
    skipWhitespaceAt(offset)
  }

  private func skipWhitespaceAt(_ offset: Int) -> Int {
    var pos = offset
    while pos < data.count {
      let b = data[pos]
      if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x00 || b == 0x0C {
        pos += 1
      } else {
        break
      }
    }
    return pos
  }

  // MARK: - Traditional XRef

  private func parseTraditionalXRef(at offset: Int, into table: inout PDFXRefTable) throws -> PDFTrailer {
    var reader = DataReader(data: data)
    reader.position = offset + 4 // skip "xref"
    reader.skipWhitespace()

    while !reader.isAtEnd {
      reader.skipWhitespaceAndComments()
      // Check if we've reached "trailer"
      if reader.position + 7 <= data.count {
        let peek = Data(data[reader.position ..< reader.position + 7])
        if String(data: peek, encoding: .ascii) == "trailer" {
          break
        }
      }
      // Check if we've reached a non-digit (not a subsection header)
      if let byte = reader.peekByte(), !(byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) {
        break
      }

      // Read subsection header: startObj count
      let startObj = try readInt(from: &reader)
      reader.skipWhitespace()
      let count = try readInt(from: &reader)
      reader.skipWhitespace()

      // Safety: cap entries per subsection to avoid runaway loops on corrupt data
      guard count >= 0, count < 10_000_000 else { break }

      for i in 0 ..< count {
        let objNum = startObj + i
        reader.skipWhitespaceAndComments()

        guard reader.remaining >= 16 else { break }

        // Parse offset (10 digits), generation (5 digits), type char (f/n)
        let entryOffset = try readInt(from: &reader)
        reader.skipWhitespace()
        let gen = try readInt(from: &reader)
        reader.skipWhitespace()

        // Read type character (f or n)
        guard !reader.isAtEnd else { break }
        let typeByte = try reader.readByte()

        if typeByte == UInt8(ascii: "n") {
          table.addEntry(objectNumber: objNum, entry: PDFXRefEntry(
            type: .inUse(offset: entryOffset + contentOffset), generation: gen,
          ))
        } else {
          table.addEntry(objectNumber: objNum, entry: PDFXRefEntry(
            type: .free, generation: gen,
          ))
        }
      }
    }

    // Parse trailer dictionary
    var parser = PDFParser(data: data, position: reader.position + 7) // skip "trailer"
    guard let trailerObj = try parser.parseObject(),
          let dict = trailerObj.dictionaryValue
    else {
      throw PDFError.xrefError("Invalid trailer dictionary")
    }

    return PDFTrailer(dictionary: dict)
  }

  // MARK: - XRef Stream

  private func parseXRefStream(at offset: Int, into table: inout PDFXRefTable) throws -> PDFTrailer {
    var parser = PDFParser(data: data, position: offset)
    guard let (_, obj) = try parser.parseIndirectObject(),
          case let .stream(dict, streamData) = obj
    else {
      throw PDFError.xrefError("Invalid xref stream at offset \(offset)")
    }

    // Decompress if needed
    var rawData: Data
    let filterName: String? = dict["Filter"]?.nameValue ?? dict["Filter"]?.arrayValue?.first?.nameValue
    if filterName == "FlateDecode" {
      rawData = try DeflateDecompressor.decompress(streamData)
    } else {
      rawData = streamData
    }

    // Apply predictor if specified
    if let decodeParms = dict["DecodeParms"]?.dictionaryValue,
       let predictor = decodeParms["Predictor"]?.intValue, predictor >= 10
    {
      let columns = decodeParms["Columns"]?.intValue ?? 1
      rawData = applyPNGPredictor(data: rawData, columns: columns)
    }

    // Parse W array
    guard let wArray = dict["W"]?.arrayValue,
          wArray.count == 3,
          let w0 = wArray[0].intValue,
          let w1 = wArray[1].intValue,
          let w2 = wArray[2].intValue
    else {
      throw PDFError.xrefError("Invalid W array in xref stream")
    }

    let entrySize = w0 + w1 + w2

    // Parse Index array (default: [0 Size])
    let indexRanges: [(start: Int, count: Int)]
    if let indexArray = dict["Index"]?.arrayValue {
      var ranges: [(Int, Int)] = []
      for i in stride(from: 0, to: indexArray.count - 1, by: 2) {
        if let s = indexArray[i].intValue, let c = indexArray[i + 1].intValue {
          ranges.append((s, c))
        }
      }
      indexRanges = ranges
    } else if let size = dict["Size"]?.intValue {
      indexRanges = [(0, size)]
    } else {
      throw PDFError.xrefError("Missing Size in xref stream")
    }

    var dataOffset = 0
    for (startObj, count) in indexRanges {
      for i in 0 ..< count {
        guard dataOffset + entrySize <= rawData.count else { break }

        let field1 = readField(from: rawData, offset: dataOffset, width: w0, defaultValue: 1)
        let field2 = readField(from: rawData, offset: dataOffset + w0, width: w1, defaultValue: 0)
        let field3 = readField(from: rawData, offset: dataOffset + w0 + w1, width: w2, defaultValue: 0)

        let objNum = startObj + i
        switch field1 {
        case 0: // free
          table.addEntry(objectNumber: objNum, entry: PDFXRefEntry(type: .free, generation: field3))
        case 1: // in use
          table.addEntry(objectNumber: objNum, entry: PDFXRefEntry(
            type: .inUse(offset: field2 + contentOffset), generation: field3,
          ))
        case 2: // compressed
          table.addEntry(objectNumber: objNum, entry: PDFXRefEntry(
            type: .compressed(objectStreamNumber: field2, indexInStream: field3), generation: 0,
          ))
        default:
          break
        }

        dataOffset += entrySize
      }
    }

    // The xref stream dict IS the trailer
    return PDFTrailer(dictionary: dict)
  }

  private func readField(from data: Data, offset: Int, width: Int, defaultValue: Int) -> Int {
    guard width > 0 else { return defaultValue }
    var value = 0
    for i in 0 ..< width {
      guard offset + i < data.count else { return defaultValue }
      value = (value << 8) | Int(data[offset + i])
    }
    return value
  }

  private func readInt(from reader: inout DataReader) throws -> Int {
    let start = reader.position
    while !reader.isAtEnd {
      let byte = reader.data[reader.position]
      if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
        reader.position += 1
      } else {
        break
      }
    }
    let numData = Data(reader.data[start ..< reader.position])
    guard let str = String(data: numData, encoding: .ascii),
          let value = Int(str)
    else {
      throw PDFError.xrefError("Expected integer at position \(start)")
    }
    return value
  }

  /// Apply PNG predictor (type 10-14) to decoded stream data
  private func applyPNGPredictor(data: Data, columns: Int) -> Data {
    let rowSize = columns + 1 // +1 for the filter byte
    guard rowSize > 1, data.count >= rowSize else { return data }

    var output = Data()
    let rowCount = data.count / rowSize
    var previousRow = [UInt8](repeating: 0, count: columns)

    for row in 0 ..< rowCount {
      let offset = row * rowSize
      guard offset < data.count else { break }
      let filterType = data[offset]
      var currentRow = [UInt8](repeating: 0, count: columns)

      for col in 0 ..< columns {
        let byteOffset = offset + 1 + col
        guard byteOffset < data.count else { break }
        let raw = data[byteOffset]

        switch filterType {
        case 0: // None
          currentRow[col] = raw
        case 1: // Sub
          let left: UInt8 = col > 0 ? currentRow[col - 1] : 0
          currentRow[col] = raw &+ left
        case 2: // Up
          currentRow[col] = raw &+ previousRow[col]
        case 3: // Average
          let left: UInt8 = col > 0 ? currentRow[col - 1] : 0
          let up = previousRow[col]
          currentRow[col] = raw &+ UInt8((Int(left) + Int(up)) / 2)
        case 4: // Paeth
          let left: Int = col > 0 ? Int(currentRow[col - 1]) : 0
          let up = Int(previousRow[col])
          let upLeft: Int = col > 0 ? Int(previousRow[col - 1]) : 0
          currentRow[col] = raw &+ paethPredictor(left, up, upLeft)
        default:
          currentRow[col] = raw
        }
      }

      output.append(contentsOf: currentRow)
      previousRow = currentRow
    }

    return output
  }

  private func paethPredictor(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
    let p = a + b - c
    let pa = abs(p - a)
    let pb = abs(p - b)
    let pc = abs(p - c)
    if pa <= pb, pa <= pc { return UInt8(a & 0xFF) }
    if pb <= pc { return UInt8(b & 0xFF) }
    return UInt8(c & 0xFF)
  }
}
