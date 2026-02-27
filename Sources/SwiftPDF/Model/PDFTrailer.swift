import Foundation

struct PDFTrailer: Sendable {
  let dictionary: [String: PDFObject]

  var size: Int? {
    dictionary["Size"]?.intValue
  }

  var root: PDFObjectIdentifier? {
    dictionary["Root"]?.referenceValue
  }

  var prev: Int? {
    dictionary["Prev"]?.intValue
  }

  var encrypt: PDFObject? {
    dictionary["Encrypt"]
  }
}
