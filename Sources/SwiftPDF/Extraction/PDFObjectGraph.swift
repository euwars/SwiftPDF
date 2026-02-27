import DequeModule
import Foundation

struct PDFObjectGraph {
  let document: PDFDocument

  /// BFS to collect all objects referenced by the given root objects.
  /// Skips /Parent references to avoid pulling in the entire page tree.
  func collectDependencies(from rootIds: Set<PDFObjectIdentifier>) throws -> Set<PDFObjectIdentifier> {
    var visited = Set<PDFObjectIdentifier>()
    var queue = Deque(rootIds)

    while let current = queue.popFirst() {
      guard visited.insert(current).inserted else { continue }

      let obj = try document.resolveObject(current)
      let refs = collectReferences(from: obj, skipParent: true)
      for ref in refs {
        if !visited.contains(ref) {
          queue.append(ref)
        }
      }
    }

    return visited
  }

  /// Collect all PDFObjectIdentifier references from an object, optionally skipping /Parent
  private func collectReferences(from obj: PDFObject, skipParent: Bool) -> [PDFObjectIdentifier] {
    var refs: [PDFObjectIdentifier] = []
    collectRefsRecursive(obj, skipParent: skipParent, refs: &refs, parentKey: nil)
    return refs
  }

  private func collectRefsRecursive(
    _ obj: PDFObject,
    skipParent: Bool,
    refs: inout [PDFObjectIdentifier],
    parentKey: String?,
  ) {
    switch obj {
    case let .reference(id):
      if skipParent, parentKey == "Parent" { return }
      refs.append(id)

    case let .array(items):
      for item in items {
        collectRefsRecursive(item, skipParent: skipParent, refs: &refs, parentKey: nil)
      }

    case let .dictionary(dict):
      for (key, value) in dict {
        collectRefsRecursive(value, skipParent: skipParent, refs: &refs, parentKey: key)
      }

    case let .stream(dict, _):
      for (key, value) in dict {
        collectRefsRecursive(value, skipParent: skipParent, refs: &refs, parentKey: key)
      }

    default:
      break
    }
  }
}
