import Foundation
import Synchronization

final class PDFDocument: @unchecked Sendable {
  let data: Data
  let xrefTable: PDFXRefTable
  let trailer: PDFTrailer
  private let objectCache = Mutex<[Int: PDFObject]>([:])
  private let objectStreamCache = Mutex<[Int: [Int: PDFObject]]>([:])

  /// Lazily-built fallback map: object number -> file offset, built by scanning for "N G obj" patterns
  private let scannedOffsets = Mutex<[Int: Int]?>(nil)

  /// Byte offset of %PDF- header (non-zero if junk data precedes it)
  let contentOffset: Int

  init(data: Data) throws {
    self.data = data

    // Find %PDF- header, allowing junk bytes before it (common in real-world PDFs)
    guard data.count >= 8 else {
      throw PDFError.invalidPDF("File too small")
    }
    let marker = Array("%PDF-".utf8)
    var headerOffset: Int?
    let searchLimit = min(data.count - marker.count, 1024)
    for i in 0 ... searchLimit {
      var match = true
      for j in 0 ..< marker.count {
        if data[i + j] != marker[j] { match = false; break }
      }
      if match { headerOffset = i; break }
    }
    guard let offset = headerOffset else {
      throw PDFError.invalidPDF("Missing %PDF- header")
    }
    contentOffset = offset

    // Parse xref (pass content offset for adjusting byte positions)
    let xrefParser = PDFXRefParser(data: data, contentOffset: offset)
    let (table, trailer) = try xrefParser.parse()
    xrefTable = table
    self.trailer = trailer

    // Check for encryption
    if trailer.encrypt != nil {
      throw PDFError.encryptedPDF
    }
  }

  // MARK: - Object resolution

  func resolveObject(_ id: PDFObjectIdentifier) throws -> PDFObject {
    try resolveObject(objectNumber: id.objectNumber)
  }

  func resolveObject(objectNumber: Int) throws -> PDFObject {
    if let cached = objectCache.withLock({ $0[objectNumber] }) {
      return cached
    }

    // Check if object is in an object stream
    if let info = xrefTable.compressedInfo(for: objectNumber) {
      let obj = try resolveFromObjectStream(
        objectNumber: objectNumber,
        streamObjNum: info.streamObjNum,
        index: info.index,
      )
      objectCache.withLock { $0[objectNumber] = obj }
      return obj
    }

    // Try xref offset first
    if let offset = xrefTable.offset(for: objectNumber),
       offset >= 0, offset < data.count
    {
      var parser = PDFParser(data: data, position: offset)
      if let (_, obj) = try? parser.parseIndirectObject() {
        objectCache.withLock { $0[objectNumber] = obj }
        return obj
      }
    }

    // Fallback: scan file for "N G obj" pattern (handles bad/missing xref offsets)
    let map = getScannedOffsets()
    if let scannedOffset = map[objectNumber] {
      var parser = PDFParser(data: data, position: scannedOffset)
      if let (_, obj) = try? parser.parseIndirectObject() {
        objectCache.withLock { $0[objectNumber] = obj }
        return obj
      }
    }

    return .null
  }

  /// Resolve an object, following indirect references
  func resolve(_ obj: PDFObject) throws -> PDFObject {
    if case let .reference(id) = obj {
      return try resolveObject(id)
    }
    return obj
  }

  // MARK: - Object streams

  private func resolveFromObjectStream(objectNumber: Int, streamObjNum: Int, index _: Int) throws -> PDFObject {
    // Check cache
    if let cached = objectStreamCache.withLock({ $0[streamObjNum]?[objectNumber] }) {
      return cached
    }

    // Parse the object stream — must resolve directly (not from another object stream)
    // to avoid circular references
    guard let offset = xrefTable.offset(for: streamObjNum),
          offset >= 0, offset < data.count
    else {
      return .null
    }
    var streamParser = PDFParser(data: data, position: offset)
    guard let (_, streamObj) = try? streamParser.parseIndirectObject(),
          case let .stream(dict, rawData) = streamObj
    else {
      return .null
    }

    // Decompress
    let decompressed: Data
    let filterName: String? = {
      if let name = dict["Filter"]?.nameValue { return name }
      if let arr = dict["Filter"]?.arrayValue, let first = arr.first?.nameValue { return first }
      return nil
    }()
    if filterName == "FlateDecode" {
      decompressed = try DeflateDecompressor.decompress(rawData)
    } else {
      decompressed = rawData
    }

    guard let n = dict["N"]?.intValue,
          let first = dict["First"]?.intValue
    else {
      throw PDFError.parsingError("Object stream missing N or First")
    }

    // Parse the header: pairs of (objNum, offset) relative to First
    var headerParser = PDFParser(data: decompressed, position: 0)
    var objectOffsets: [(objNum: Int, offset: Int)] = []
    for _ in 0 ..< n {
      guard let objNumToken = try headerParser.parseObject(),
            let objNum = objNumToken.intValue,
            let offsetToken = try headerParser.parseObject(),
            let offset = offsetToken.intValue
      else {
        break
      }
      objectOffsets.append((objNum, offset))
    }

    // Parse each object
    var streamObjects: [Int: PDFObject] = [:]
    for i in 0 ..< objectOffsets.count {
      let objNum = objectOffsets[i].objNum
      let objOffset = first + objectOffsets[i].offset
      var objParser = PDFParser(data: decompressed, position: objOffset)
      if let obj = try objParser.parseObject() {
        streamObjects[objNum] = obj
      }
    }

    objectStreamCache.withLock { $0[streamObjNum] = streamObjects }
    return streamObjects[objectNumber] ?? .null
  }

  // MARK: - Object scanning fallback

  /// Build a map of object number -> byte offset by scanning the file for "N G obj" patterns.
  /// This is used as a fallback when xref offsets are wrong or missing.
  /// Lazily computed and cached; the scan is O(file_size) and happens at most once.
  private func getScannedOffsets() -> [Int: Int] {
    if let cached = scannedOffsets.withLock({ $0 }) {
      return cached
    }

    var map: [Int: Int] = [:]
    let bytes = data
    let count = bytes.count

    // Scan for " obj" (0x20 0x6F 0x62 0x6A) then look backwards for "N G"
    var i = 3 // minimum: "0 0 obj" means " obj" starts at index 3
    while i + 3 < count {
      // Fast check for " obj"
      guard bytes[i] == 0x20,
            bytes[i + 1] == 0x6F, // 'o'
            bytes[i + 2] == 0x62, // 'b'
            bytes[i + 3] == 0x6A  // 'j'
      else {
        i += 1
        continue
      }

      // Verify followed by whitespace, delimiter, or EOF (not "object" etc.)
      let afterObj = i + 4
      if afterObj < count {
        let c = bytes[afterObj]
        guard c <= 0x20 || c == 0x3C || c == 0x2F || c == 0x5B || c == 0x28 else {
          i += 1
          continue
        }
      }

      // Look backwards past generation number
      var pos = i - 1
      while pos >= 0, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos -= 1 }
      let genStart = pos + 1
      guard genStart < i else { i += 1; continue } // need at least 1 digit for gen

      // Expect whitespace between objNum and gen
      guard pos >= 0, bytes[pos] == 0x20 || bytes[pos] == 0x09 else { i += 1; continue }
      pos -= 1

      // Look backwards past object number
      while pos >= 0, bytes[pos] >= 0x30, bytes[pos] <= 0x39 { pos -= 1 }
      let objNumStart = pos + 1
      guard objNumStart < genStart - 1 else { i += 1; continue } // need at least 1 digit

      // Verify preceded by whitespace/newline or start of file
      if pos >= 0 {
        let c = bytes[pos]
        guard c == 0x0A || c == 0x0D || c == 0x20 || c == 0x09 || c == 0x00 else {
          i += 1
          continue
        }
      }

      // Parse object number
      var objNum = 0
      for j in objNumStart ..< (genStart - 1) {
        objNum = objNum &* 10 &+ Int(bytes[j] - 0x30)
      }

      // Later occurrence wins (incremental updates append newer versions)
      map[objNum] = objNumStart

      i = afterObj
    }

    scannedOffsets.withLock { $0 = map }
    return map
  }

  // MARK: - Page tree

  func getPages() throws -> [(object: PDFObject, id: PDFObjectIdentifier)] {
    guard let rootRef = trailer.root else {
      throw PDFError.invalidPDF("No Root in trailer")
    }

    let catalog = try resolveObject(rootRef)
    guard let pagesRef = catalog["Pages"]?.referenceValue else {
      throw PDFError.invalidPDF("No Pages in catalog")
    }

    var pages: [(PDFObject, PDFObjectIdentifier)] = []
    try collectPages(ref: pagesRef, inheritedAttributes: [:], into: &pages)
    return pages
  }

  private func collectPages(
    ref: PDFObjectIdentifier,
    inheritedAttributes: [String: PDFObject],
    into pages: inout [(PDFObject, PDFObjectIdentifier)],
  ) throws {
    let obj = try resolveObject(ref)
    guard let dict = obj.dictionaryValue else { return }

    let type = dict["Type"]?.nameValue

    // Infer type if /Type is missing:
    // - Has /Kids -> Pages node
    // - Has /Contents or /MediaBox but no /Kids -> Page leaf
    let effectiveType: String? = if let t = type {
      t
    } else if dict["Kids"] != nil {
      "Pages"
    } else if dict["Contents"] != nil || dict["MediaBox"] != nil {
      "Page"
    } else {
      type
    }

    // Collect inheritable attributes
    var inherited = inheritedAttributes
    for key in ["MediaBox", "CropBox", "Resources", "Rotate"] {
      if let value = dict[key] {
        inherited[key] = value
      }
    }

    if effectiveType == "Page" {
      // Materialize inherited attributes
      var pageDict = dict
      for (key, value) in inherited {
        if pageDict[key] == nil {
          pageDict[key] = value
        }
      }

      let pageObj: PDFObject = if case let .stream(_, streamData) = obj {
        .stream(pageDict, streamData)
      } else {
        .dictionary(pageDict)
      }
      pages.append((pageObj, ref))
    } else if effectiveType == "Pages" {
      // Traverse kids
      if let kids = dict["Kids"]?.arrayValue {
        for kid in kids {
          if let kidRef = kid.referenceValue {
            try collectPages(ref: kidRef, inheritedAttributes: inherited, into: &pages)
          }
        }
      }
    }
  }

  var pageCount: Int {
    (try? getPages().count) ?? 0
  }
}
