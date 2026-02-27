import Foundation

public enum PDFError: Error, CustomStringConvertible {
  case invalidPDF(String)
  case parsingError(String)
  case xrefError(String)
  case unsupportedFeature(String)
  case encryptedPDF
  case invalidPageIndex(Int)
  case decompressionError(String)
  case writeError(String)
  case fileError(String)

  public var description: String {
    switch self {
    case let .invalidPDF(msg): "Invalid PDF: \(msg)"
    case let .parsingError(msg): "Parsing error: \(msg)"
    case let .xrefError(msg): "XRef error: \(msg)"
    case let .unsupportedFeature(msg): "Unsupported feature: \(msg)"
    case .encryptedPDF: "Encrypted PDFs are not supported"
    case let .invalidPageIndex(idx): "Invalid page index: \(idx)"
    case let .decompressionError(msg): "Decompression error: \(msg)"
    case let .writeError(msg): "Write error: \(msg)"
    case let .fileError(msg): "File error: \(msg)"
    }
  }
}
