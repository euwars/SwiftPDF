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

  // MARK: - Render Session (open PDF once, render many pages)

  /// A render session that writes the PDF to disk once and renders pages from it.
  /// Use this when rendering multiple pages to avoid re-writing the PDF for each page.
  public struct RenderSession: @unchecked Sendable {
    private let renderer: PDFRenderer
    private let tempDir: String
    private let inputPath: String
    public let pageCount: Int
    private let fileManager: FileManager

    init(pdfData: Data) throws {
      self.renderer = PDFRenderer()
      try renderer.validateVips()

      let document = try PDFDocument(data: pdfData)
      self.pageCount = try document.getPages().count

      self.fileManager = FileManager.default
      self.tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
      try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

      self.inputPath = (tempDir as NSString).appendingPathComponent("input.pdf")
      guard fileManager.createFile(atPath: inputPath, contents: pdfData) else {
        throw PDFError.fileError("Cannot write temporary PDF file")
      }
    }

    /// Render a single page to image data. Can be called repeatedly for different pages.
    public func renderPage(at pageIndex: Int, dpi: Double = 144, format: ImageFormat = .png) throws -> Data {
      guard pageIndex >= 0, pageIndex < pageCount else {
        throw PDFError.invalidPageIndex(pageIndex)
      }
      let outputPath = (tempDir as NSString).appendingPathComponent("page\(pageIndex).\(format.fileExtension)")
      try renderer.renderPage(pdfPath: inputPath, pageIndex: pageIndex, outputPath: outputPath, dpi: dpi, format: format)
      defer { try? fileManager.removeItem(atPath: outputPath) }
      guard let imageData = fileManager.contents(atPath: outputPath) else {
        throw PDFError.renderError("Failed to read rendered image for page \(pageIndex)")
      }
      return imageData
    }

    /// Clean up temporary files. Call when done rendering.
    public func cleanup() {
      try? fileManager.removeItem(atPath: tempDir)
    }
  }

  /// Create a render session for efficiently rendering multiple pages from the same PDF.
  /// The PDF is written to disk once. Call `cleanup()` when done.
  public func renderSession(pdfData: Data) throws -> RenderSession {
    try RenderSession(pdfData: pdfData)
  }

  // MARK: - Rendering (PDF → image via libvips)

  private var renderer: PDFRenderer { PDFRenderer() }

  /// Render a single page of a PDF to image data
  public func renderPage(from pdfData: Data, at pageIndex: Int, dpi: Double = 144, format: ImageFormat = .png) throws -> Data {
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
    let outputPath = (tempDir as NSString).appendingPathComponent("page.\(format.fileExtension)")

    guard fileManager.createFile(atPath: inputPath, contents: pdfData) else {
      throw PDFError.fileError("Cannot write temporary PDF file")
    }

    try renderer.renderPage(pdfPath: inputPath, pageIndex: pageIndex, outputPath: outputPath, dpi: dpi, format: format)

    guard let imageData = fileManager.contents(atPath: outputPath) else {
      throw PDFError.renderError("Failed to read rendered image for page \(pageIndex)")
    }
    return imageData
  }

  /// Render all pages of a PDF to image data sequentially
  public func renderPages(pdfData: Data, dpi: Double = 144, format: ImageFormat = .png) throws -> [Data] {
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
      let outputPath = (tempDir as NSString).appendingPathComponent("page\(i).\(format.fileExtension)")
      try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi, format: format)
      guard let imageData = fileManager.contents(atPath: outputPath) else {
        throw PDFError.renderError("Failed to read rendered image for page \(i)")
      }
      results.append(imageData)
    }
    return results
  }

  /// Render all pages of a PDF to image data concurrently
  public func renderPages(pdfData: Data, dpi: Double = 144, format: ImageFormat = .png, concurrency: Int? = nil) async throws -> [Data] {
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
        let outputPath = (tempDir as NSString).appendingPathComponent("page\(i).\(format.fileExtension)")
        group.addTask {
          try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi, format: format)
          guard let imageData = FileManager.default.contents(atPath: outputPath) else {
            throw PDFError.renderError("Failed to read rendered image for page \(i)")
          }
          return (i, imageData)
        }
        nextIndex += 1
      }

      var results = Array<Data?>(repeating: nil, count: count)
      for try await (index, data) in group {
        results[index] = data

        if nextIndex < count {
          let i = nextIndex
          let outputPath = (tempDir as NSString).appendingPathComponent("page\(i).\(format.fileExtension)")
          group.addTask {
            try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi, format: format)
            guard let imageData = FileManager.default.contents(atPath: outputPath) else {
              throw PDFError.renderError("Failed to read rendered image for page \(i)")
            }
            return (i, imageData)
          }
          nextIndex += 1
        }
      }

      return results.map { $0! }
    }
  }

  /// Render all pages of a PDF file to image files in the output directory
  public func renderPages(inputPath: String, outputDirectory: String, dpi: Double = 144, format: ImageFormat = .png) throws -> [String] {
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
        .appendingPathComponent("\(baseName)_page\(i + 1).\(format.fileExtension)")
      try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi, format: format)
      outputPaths.append(outputPath)
    }
    return outputPaths
  }

  /// Render all pages of a PDF file to image files concurrently
  public func renderPages(inputPath: String, outputDirectory: String, dpi: Double = 144, format: ImageFormat = .png, concurrency: Int? = nil) async throws -> [String] {
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
          .appendingPathComponent("\(baseName)_page\(i + 1).\(format.fileExtension)")
        group.addTask {
          try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi, format: format)
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
            .appendingPathComponent("\(baseName)_page\(i + 1).\(format.fileExtension)")
          group.addTask {
            try renderer.renderPage(pdfPath: inputPath, pageIndex: i, outputPath: outputPath, dpi: dpi, format: format)
            return (i, outputPath)
          }
          nextIndex += 1
        }
      }

      return results.map { $0! }
    }
  }
}
