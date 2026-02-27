import Foundation

struct PDFXRefEntry: Sendable {
  enum EntryType: Sendable {
    case free
    case inUse(offset: Int)
    case compressed(objectStreamNumber: Int, indexInStream: Int)
  }

  let type: EntryType
  let generation: Int
}

struct PDFXRefTable: Sendable {
  var entries: [Int: PDFXRefEntry] = [:]

  mutating func addEntry(objectNumber: Int, entry: PDFXRefEntry) {
    // First entry wins (most recent xref section is parsed first)
    if entries[objectNumber] == nil {
      entries[objectNumber] = entry
    }
  }

  func offset(for objectNumber: Int) -> Int? {
    guard let entry = entries[objectNumber],
          case let .inUse(offset) = entry.type else { return nil }
    return offset
  }

  func compressedInfo(for objectNumber: Int) -> (streamObjNum: Int, index: Int)? {
    guard let entry = entries[objectNumber],
          case let .compressed(streamNum, index) = entry.type else { return nil }
    return (streamNum, index)
  }
}
