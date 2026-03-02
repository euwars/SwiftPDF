import Foundation

public struct PDF: Sendable {
  public init() {}

  /// Split a PDF into individual pages, returning each page as PDF Data
  public func split(pdfData: Data) throws -> [Data] {
    let document = try PDFDocument(data: pdfData)
    let extractor = PDFPageExtractor(document: document)
    let count = try document.getPages().count

    var results: [Data] = []
    for i in 0 ..< count {
      let pageData = try extractor.extractPage(at: i)
      results.append(pageData)
    }
    return results
  }

  /// Split a PDF into individual pages concurrently
  public func split(pdfData: Data, concurrency: Int? = nil) async throws -> [Data] {
    let document = try PDFDocument(data: pdfData)
    let pages = try document.getPages()

    guard !pages.isEmpty else { return [] }

    let maxConcurrency = concurrency ?? ProcessInfo.processInfo.activeProcessorCount

    return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      var nextIndex = 0

      // Seed initial batch
      for _ in 0 ..< min(maxConcurrency, pages.count) {
        let i = nextIndex
        let (pageObj, pageId) = pages[i]
        group.addTask {
          let extractor = PDFPageExtractor(document: document)
          return (i, try extractor.extractPage(pageObj: pageObj, pageId: pageId))
        }
        nextIndex += 1
      }

      // Collect results and feed more work
      var results = Array<Data?>(repeating: nil, count: pages.count)
      for try await (index, data) in group {
        results[index] = data

        if nextIndex < pages.count {
          let i = nextIndex
          let (pageObj, pageId) = pages[i]
          group.addTask {
            let extractor = PDFPageExtractor(document: document)
            return (i, try extractor.extractPage(pageObj: pageObj, pageId: pageId))
          }
          nextIndex += 1
        }
      }

      return results.map { $0! }
    }
  }

  /// Split a PDF file into individual page files in the output directory
  public func split(inputPath: String, outputDirectory: String) throws -> [String] {
    let fileManager = FileManager.default

    guard let pdfData = fileManager.contents(atPath: inputPath) else {
      throw PDFError.fileError("Cannot read file: \(inputPath)")
    }

    // Create output directory if needed
    if !fileManager.fileExists(atPath: outputDirectory) {
      try fileManager.createDirectory(
        atPath: outputDirectory,
        withIntermediateDirectories: true,
      )
    }

    let pages = try split(pdfData: pdfData)

    let baseName = (inputPath as NSString).deletingPathExtension
      .components(separatedBy: "/").last ?? "page"

    var outputPaths: [String] = []
    for (i, pageData) in pages.enumerated() {
      let outputPath = (outputDirectory as NSString)
        .appendingPathComponent("\(baseName)_page\(i + 1).pdf")
      guard fileManager.createFile(atPath: outputPath, contents: pageData) else {
        throw PDFError.fileError("Cannot write file: \(outputPath)")
      }
      outputPaths.append(outputPath)
    }
    return outputPaths
  }

  /// Split a PDF file into individual page files concurrently
  public func split(inputPath: String, outputDirectory: String, concurrency: Int? = nil) async throws -> [String] {
    let fileManager = FileManager.default

    guard let pdfData = fileManager.contents(atPath: inputPath) else {
      throw PDFError.fileError("Cannot read file: \(inputPath)")
    }

    // Create output directory if needed
    if !fileManager.fileExists(atPath: outputDirectory) {
      try fileManager.createDirectory(
        atPath: outputDirectory,
        withIntermediateDirectories: true,
      )
    }

    let pages = try await split(pdfData: pdfData, concurrency: concurrency)

    let baseName = (inputPath as NSString).deletingPathExtension
      .components(separatedBy: "/").last ?? "page"

    var outputPaths: [String] = []
    for (i, pageData) in pages.enumerated() {
      let outputPath = (outputDirectory as NSString)
        .appendingPathComponent("\(baseName)_page\(i + 1).pdf")
      guard fileManager.createFile(atPath: outputPath, contents: pageData) else {
        throw PDFError.fileError("Cannot write file: \(outputPath)")
      }
      outputPaths.append(outputPath)
    }
    return outputPaths
  }

  /// Extract a single page from a PDF
  public func extractPage(from pdfData: Data, at pageIndex: Int) throws -> Data {
    let document = try PDFDocument(data: pdfData)
    let extractor = PDFPageExtractor(document: document)
    return try extractor.extractPage(at: pageIndex)
  }

  /// Get the number of pages in a PDF
  public func pageCount(in pdfData: Data) throws -> Int {
    let document = try PDFDocument(data: pdfData)
    return try document.getPages().count
  }

  // MARK: - Rendering (PDF → PNG via libvips)

  private var renderer: PDFRenderer { PDFRenderer() }

  /// Render a single page of a PDF to PNG data
  public func renderPage(from pdfData: Data, at pageIndex: Int, dpi: Double = 144) throws -> Data {
    let renderer = self.renderer
    try renderer.validateVips()

    let document = try PDFDocument(data: pdfData)
    let count = try document.getPages().count
    guard pageIndex >= 0, pageIndex < count else {
      throw PDFError.invalidPageIndex(pageIndex)
    }

    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path

    try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: tempDir) }

    let inputPath = (tempDir as NSString).appendingPathComponent("input.pdf")
    let outputPath = (tempDir as NSString).appendingPathComponent("page.png")

    guard fileManager.createFile(atPath: inputPath, contents: pdfData) else {
      throw PDFError.fileError("Cannot write temporary PDF file")
    }

    try renderer.renderPage(pdfPath: inputPath, pageIndex: pageIndex, outputPath: outputPath, dpi: dpi)

    guard let pngData = fileManager.contents(atPath: outputPath) else {
      throw PDFError.renderError("Failed to read rendered PNG")
    }
    return pngData
  }

  /// Render all pages of a PDF to PNG data
  public func renderPages(pdfData: Data, dpi: Double = 144) throws -> [Data] {
    let renderer = self.renderer
    try renderer.validateVips()

    let document = try PDFDocument(data: pdfData)
    let count = try document.getPages().count

    guard count > 0 else { return [] }

    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path

    try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: tempDir) }

    let inputPath = (tempDir as NSString).appendingPathComponent("input.pdf")
    guard fileManager.createFile(atPath: inputPath, contents: pdfData) else {
      throw PDFError.fileError("Cannot write temporary PDF file")
    }

    var results: [Data] = []
    for i in 0 ..< count {
      let outputPath = (tempDir as NSString).appendingPathComponent("page\(i).png")
      try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi)
      guard let pngData = fileManager.contents(atPath: outputPath) else {
        throw PDFError.renderError("Failed to read rendered PNG for page \(i)")
      }
      results.append(pngData)
    }
    return results
  }

  /// Render all pages of a PDF to PNG data concurrently
  public func renderPages(pdfData: Data, dpi: Double = 144, concurrency: Int? = nil) async throws -> [Data] {
    let renderer = self.renderer
    try renderer.validateVips()

    let document = try PDFDocument(data: pdfData)
    let count = try document.getPages().count

    guard count > 0 else { return [] }

    let maxConcurrency = concurrency ?? ProcessInfo.processInfo.activeProcessorCount
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path

    try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: tempDir) }

    let inputPath = (tempDir as NSString).appendingPathComponent("input.pdf")
    guard fileManager.createFile(atPath: inputPath, contents: pdfData) else {
      throw PDFError.fileError("Cannot write temporary PDF file")
    }

    return try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      var nextIndex = 0

      for _ in 0 ..< min(maxConcurrency, count) {
        let i = nextIndex
        let outputPath = (tempDir as NSString).appendingPathComponent("page\(i).png")
        group.addTask {
          try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi)
          guard let pngData = FileManager.default.contents(atPath: outputPath) else {
            throw PDFError.renderError("Failed to read rendered PNG for page \(i)")
          }
          return (i, pngData)
        }
        nextIndex += 1
      }

      var results = Array<Data?>(repeating: nil, count: count)
      for try await (index, data) in group {
        results[index] = data

        if nextIndex < count {
          let i = nextIndex
          let outputPath = (tempDir as NSString).appendingPathComponent("page\(i).png")
          group.addTask {
            try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi)
            guard let pngData = FileManager.default.contents(atPath: outputPath) else {
              throw PDFError.renderError("Failed to read rendered PNG for page \(i)")
            }
            return (i, pngData)
          }
          nextIndex += 1
        }
      }

      return results.map { $0! }
    }
  }

  /// Render all pages of a PDF file to PNG files in the output directory
  public func renderPages(inputPath: String, outputDirectory: String, dpi: Double = 144) throws -> [String] {
    let renderer = self.renderer
    try renderer.validateVips()

    let fileManager = FileManager.default

    guard let pdfData = fileManager.contents(atPath: inputPath) else {
      throw PDFError.fileError("Cannot read file: \(inputPath)")
    }

    if !fileManager.fileExists(atPath: outputDirectory) {
      try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    }

    let document = try PDFDocument(data: pdfData)
    let count = try document.getPages().count

    guard count > 0 else { return [] }

    let baseName = (inputPath as NSString).deletingPathExtension
      .components(separatedBy: "/").last ?? "page"

    var outputPaths: [String] = []
    for i in 0 ..< count {
      let outputPath = (outputDirectory as NSString)
        .appendingPathComponent("\(baseName)_page\(i + 1).png")
      try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi)
      outputPaths.append(outputPath)
    }
    return outputPaths
  }

  /// Render all pages of a PDF file to PNG files concurrently
  public func renderPages(inputPath: String, outputDirectory: String, dpi: Double = 144, concurrency: Int? = nil) async throws -> [String] {
    let renderer = self.renderer
    try renderer.validateVips()

    let fileManager = FileManager.default

    guard let pdfData = fileManager.contents(atPath: inputPath) else {
      throw PDFError.fileError("Cannot read file: \(inputPath)")
    }

    if !fileManager.fileExists(atPath: outputDirectory) {
      try fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
    }

    let document = try PDFDocument(data: pdfData)
    let count = try document.getPages().count

    guard count > 0 else { return [] }

    let maxConcurrency = concurrency ?? ProcessInfo.processInfo.activeProcessorCount
    let baseName = (inputPath as NSString).deletingPathExtension
      .components(separatedBy: "/").last ?? "page"

    return try await withThrowingTaskGroup(of: (Int, String).self) { group in
      var nextIndex = 0

      for _ in 0 ..< min(maxConcurrency, count) {
        let i = nextIndex
        let outputPath = (outputDirectory as NSString)
          .appendingPathComponent("\(baseName)_page\(i + 1).png")
        group.addTask {
          try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi)
          return (i, outputPath)
        }
        nextIndex += 1
      }

      var results = Array<String?>(repeating: nil, count: count)
      for try await (index, path) in group {
        results[index] = path

        if nextIndex < count {
          let i = nextIndex
          let outputPath = (outputDirectory as NSString)
            .appendingPathComponent("\(baseName)_page\(i + 1).png")
          group.addTask {
            try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi)
            return (i, outputPath)
          }
          nextIndex += 1
        }
      }

      return results.map { $0! }
    }
  }
}
