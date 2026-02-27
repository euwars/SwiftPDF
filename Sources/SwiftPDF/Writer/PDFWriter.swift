import Foundation

enum PDFWriter {
  /// Serialize a set of objects into a valid PDF 1.4 file.
  /// - Parameters:
  ///   - objects: Mapping from object identifier to object
  ///   - rootRef: The reference to the catalog object
  /// - Returns: Complete PDF file data
  static func write(objects: [(PDFObjectIdentifier, PDFObject)], rootRef: PDFObjectIdentifier) -> Data {
    var output = Data()
    var offsets: [(objectNumber: Int, generation: Int, offset: Int)] = []

    // Header
    append(&output, "%PDF-1.4\n")
    // Binary comment to mark as binary
    output.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]) // %âãÏÓ\n

    // Write objects
    for (id, obj) in objects {
      let offset = output.count
      offsets.append((id.objectNumber, id.generation, offset))
      append(&output, "\(id.objectNumber) \(id.generation) obj\n")
      writeObject(obj, to: &output)
      append(&output, "\nendobj\n")
    }

    // Write xref table
    let xrefOffset = output.count
    append(&output, "xref\n")

    // Sort by object number for xref
    let sorted = offsets.sorted { $0.objectNumber < $1.objectNumber }

    // Find contiguous ranges
    var ranges: [(start: Int, entries: [(objectNumber: Int, generation: Int, offset: Int)])] = []
    // Always include object 0 (free)
    var currentRange: (start: Int, entries: [(Int, Int, Int)]) = (0, [(0, 65535, 0)])

    for entry in sorted {
      if entry.objectNumber == currentRange.start + currentRange.entries.count {
        currentRange.entries.append(entry)
      } else {
        if !currentRange.entries.isEmpty {
          ranges.append(currentRange)
        }
        currentRange = (entry.objectNumber, [entry])
      }
    }
    if !currentRange.entries.isEmpty {
      ranges.append(currentRange)
    }

    for range in ranges {
      append(&output, "\(range.start) \(range.entries.count)\n")
      for entry in range.entries {
        if entry.0 == 0, entry.2 == 0, entry.1 == 65535 {
          // Free entry for object 0
          append(&output, "0000000000 65535 f \n")
        } else {
          let offsetStr = String(format: "%010d", entry.2)
          let genStr = String(format: "%05d", entry.1)
          append(&output, "\(offsetStr) \(genStr) n \n")
        }
      }
    }

    // Trailer
    let trailerDict: [String: PDFObject] = [
      "Size": .integer((sorted.last?.objectNumber ?? 0) + 1),
      "Root": .reference(rootRef),
    ]

    append(&output, "trailer\n")
    writeDictionary(trailerDict, to: &output)
    append(&output, "\nstartxref\n\(xrefOffset)\n%%EOF\n")

    return output
  }

  // MARK: - Object serialization

  private static func writeObject(_ obj: PDFObject, to output: inout Data) {
    switch obj {
    case .null:
      append(&output, "null")
    case let .bool(v):
      append(&output, v ? "true" : "false")
    case let .integer(v):
      append(&output, "\(v)")
    case let .real(v):
      // Use a format that avoids unnecessary precision
      if v == v.rounded(), abs(v) < 1e15 {
        append(&output, "\(Int(v))")
      } else {
        append(&output, "\(v)")
      }
    case let .string(data):
      writeStringLiteral(data, to: &output)
    case let .name(name):
      writeName(name, to: &output)
    case let .array(items):
      append(&output, "[")
      for (i, item) in items.enumerated() {
        if i > 0 { append(&output, " ") }
        writeObject(item, to: &output)
      }
      append(&output, "]")
    case let .dictionary(dict):
      writeDictionary(dict, to: &output)
    case let .stream(dict, data):
      // Update Length in dict
      var streamDict = dict
      streamDict["Length"] = .integer(data.count)
      writeDictionary(streamDict, to: &output)
      append(&output, "\nstream\n")
      output.append(data)
      append(&output, "\nendstream")
    case let .reference(id):
      append(&output, "\(id.objectNumber) \(id.generation) R")
    }
  }

  private static func writeDictionary(_ dict: [String: PDFObject], to output: inout Data) {
    append(&output, "<<")
    // Sort keys for deterministic output
    for key in dict.keys.sorted() {
      guard let value = dict[key] else { continue }
      append(&output, " ")
      writeName(key, to: &output)
      append(&output, " ")
      writeObject(value, to: &output)
    }
    append(&output, " >>")
  }

  private static func writeName(_ name: String, to output: inout Data) {
    append(&output, "/")
    for byte in name.utf8 {
      if byte < 0x21 || byte > 0x7E || byte == UInt8(ascii: "#") ||
        byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") ||
        byte == UInt8(ascii: "<") || byte == UInt8(ascii: ">") ||
        byte == UInt8(ascii: "[") || byte == UInt8(ascii: "]") ||
        byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}") ||
        byte == UInt8(ascii: "/") || byte == UInt8(ascii: "%")
      {
        append(&output, String(format: "#%02X", byte))
      } else {
        output.append(byte)
      }
    }
  }

  private static func writeStringLiteral(_ data: Data, to output: inout Data) {
    append(&output, "(")
    for byte in data {
      switch byte {
      case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
        output.append(UInt8(ascii: "\\"))
        output.append(byte)
      case 0x0A:
        output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
      case 0x0D:
        output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
      default:
        output.append(byte)
      }
    }
    append(&output, ")")
  }

  private static func append(_ data: inout Data, _ string: String) {
    data.append(contentsOf: string.utf8)
  }
}
