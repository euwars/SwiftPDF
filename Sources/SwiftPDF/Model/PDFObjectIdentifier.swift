import Foundation

public struct PDFObjectIdentifier: Hashable, CustomStringConvertible, Sendable {
  public let objectNumber: Int
  public let generation: Int

  public init(objectNumber: Int, generation: Int) {
    self.objectNumber = objectNumber
    self.generation = generation
  }

  public var description: String {
    "\(objectNumber) \(generation) R"
  }
}
