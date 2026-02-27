import Foundation

struct PDFPageExtractor {
  let document: PDFDocument

  /// Extract a single page as a complete PDF
  func extractPage(at index: Int) throws -> Data {
    let pages = try document.getPages()
    guard index >= 0, index < pages.count else {
      throw PDFError.invalidPageIndex(index)
    }
    return try extractPage(pageObj: pages[index].object, pageId: pages[index].id)
  }

  /// Extract a page from pre-computed page info (avoids redundant getPages calls)
  func extractPage(pageObj: PDFObject, pageId: PDFObjectIdentifier) throws -> Data {
    guard var pageDict = pageObj.dictionaryValue else {
      throw PDFError.parsingError("Page \(pageId) is not a dictionary")
    }

    // Collect all referenced objects via BFS (skipping /Parent)
    let graph = PDFObjectGraph(document: document)
    var rootIds = Set<PDFObjectIdentifier>()

    // Add all references from the page (except /Parent)
    collectRefsExcludingParent(from: pageObj, into: &rootIds)

    let dependencies = try graph.collectDependencies(from: rootIds)
    let sortedDeps = dependencies.sorted(by: { $0.objectNumber < $1.objectNumber })

    // Build object number remapping: old -> new
    var oldToNew: [Int: Int] = [:]
    var nextObjNum = 1

    // Reserve object 1 for catalog, 2 for pages dict, 3 for page
    let catalogObjNum = nextObjNum; nextObjNum += 1
    let pagesDictObjNum = nextObjNum; nextObjNum += 1
    let pageObjNum = nextObjNum; nextObjNum += 1

    // Assign new numbers to dependencies
    for dep in sortedDeps {
      if dep.objectNumber == pageId.objectNumber { continue }
      oldToNew[dep.objectNumber] = nextObjNum
      nextObjNum += 1
    }
    oldToNew[pageId.objectNumber] = pageObjNum

    // Build the page dict with remapped references
    // Remove /Parent (we'll set it to our new Pages dict)
    pageDict.removeValue(forKey: "Parent")
    let remappedPageDict = remapReferences(in: .dictionary(pageDict), mapping: oldToNew)

    // Add /Parent pointing to our Pages dict
    var finalPageDict: [String: PDFObject] = if let d = remappedPageDict.dictionaryValue {
      d
    } else {
      pageDict
    }
    finalPageDict["Parent"] = .reference(PDFObjectIdentifier(objectNumber: pagesDictObjNum, generation: 0))

    // Build Pages dict
    let pagesDict: [String: PDFObject] = [
      "Type": .name("Pages"),
      "Kids": .array([.reference(PDFObjectIdentifier(objectNumber: pageObjNum, generation: 0))]),
      "Count": .integer(1),
    ]

    // Build catalog
    let catalogDict: [String: PDFObject] = [
      "Type": .name("Catalog"),
      "Pages": .reference(PDFObjectIdentifier(objectNumber: pagesDictObjNum, generation: 0)),
    ]

    // Collect all objects to write
    var outputObjects: [(PDFObjectIdentifier, PDFObject)] = []

    outputObjects.append((
      PDFObjectIdentifier(objectNumber: catalogObjNum, generation: 0),
      .dictionary(catalogDict),
    ))
    outputObjects.append((
      PDFObjectIdentifier(objectNumber: pagesDictObjNum, generation: 0),
      .dictionary(pagesDict),
    ))

    // Write the page object
    let finalPageObj: PDFObject = if case let .stream(_, streamData) = pageObj {
      .stream(finalPageDict, streamData)
    } else {
      .dictionary(finalPageDict)
    }
    outputObjects.append((
      PDFObjectIdentifier(objectNumber: pageObjNum, generation: 0),
      finalPageObj,
    ))

    // Write dependency objects (remapped)
    for dep in sortedDeps {
      if dep.objectNumber == pageId.objectNumber { continue }
      guard let newNum = oldToNew[dep.objectNumber] else { continue }

      let obj = try document.resolveObject(dep)
      let remapped = remapReferences(in: obj, mapping: oldToNew)
      outputObjects.append((
        PDFObjectIdentifier(objectNumber: newNum, generation: 0),
        remapped,
      ))
    }

    let rootRef = PDFObjectIdentifier(objectNumber: catalogObjNum, generation: 0)
    return PDFWriter.write(objects: outputObjects, rootRef: rootRef)
  }

  // MARK: - Reference remapping

  private func remapReferences(in obj: PDFObject, mapping: [Int: Int]) -> PDFObject {
    switch obj {
    case let .reference(id):
      if let newNum = mapping[id.objectNumber] {
        return .reference(PDFObjectIdentifier(objectNumber: newNum, generation: 0))
      }
      return obj

    case let .array(items):
      return .array(items.map { remapReferences(in: $0, mapping: mapping) })

    case let .dictionary(dict):
      var newDict: [String: PDFObject] = [:]
      for (key, value) in dict {
        newDict[key] = remapReferences(in: value, mapping: mapping)
      }
      return .dictionary(newDict)

    case let .stream(dict, data):
      var newDict: [String: PDFObject] = [:]
      for (key, value) in dict {
        newDict[key] = remapReferences(in: value, mapping: mapping)
      }
      return .stream(newDict, data)

    default:
      return obj
    }
  }

  private func collectRefsExcludingParent(from obj: PDFObject, into refs: inout Set<PDFObjectIdentifier>) {
    switch obj {
    case let .reference(id):
      refs.insert(id)
    case let .array(items):
      for item in items {
        collectRefsExcludingParent(from: item, into: &refs)
      }
    case let .dictionary(dict):
      for (key, value) in dict where key != "Parent" {
        collectRefsExcludingParent(from: value, into: &refs)
      }
    case let .stream(dict, _):
      for (key, value) in dict where key != "Parent" {
        collectRefsExcludingParent(from: value, into: &refs)
      }
    default:
      break
    }
  }
}
