# SwiftPDF

A fast, pure-Swift PDF splitter. No dependencies on PDFKit or CoreGraphics — works on macOS, iOS, tvOS, watchOS, visionOS, and Linux.

## Features

- Split a PDF into individual single-page PDFs
- Extract a specific page by index
- Get page count without extracting
- Async splitting with configurable concurrency
- Handles malformed PDFs, junk headers, broken xref tables
- Detects and rejects encrypted PDFs
- Thread-safe (`Sendable`)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/aspect-build/SwiftPDF.git", from: "1.0.0"),
]
```

Then add `"SwiftPDF"` to your target's dependencies.

### Requirements

- Swift 6.2+
- macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+ / visionOS 2+
- zlib (included on Apple platforms; on Linux install `zlib1g-dev`)

## Usage

```swift
import SwiftPDF

let splitter = PDF()
let pdfData = try Data(contentsOf: URL(fileURLWithPath: "document.pdf"))

// Get page count
let count = try splitter.pageCount(in: pdfData)

// Split into individual pages
let pages: [Data] = try splitter.split(pdfData: pdfData)

// Extract a single page (0-indexed)
let page: Data = try splitter.extractPage(from: pdfData, at: 0)

// Split directly from file path to directory
let outputFiles = try splitter.split(
  inputPath: "document.pdf",
  outputDirectory: "output/"
)
```

### Async

```swift
// Concurrent splitting (uses all cores by default)
let pages = try await splitter.split(pdfData: pdfData)

// Limit concurrency
let pages = try await splitter.split(pdfData: pdfData, concurrency: 4)
```

### Error Handling

```swift
do {
  let pages = try splitter.split(pdfData: data)
} catch let error as PDFError {
  switch error {
  case .encryptedPDF:
    print("Cannot split encrypted PDFs")
  case .invalidPDF(let reason):
    print("Invalid PDF: \(reason)")
  default:
    print("Error: \(error)")
  }
}
```

## Running Tests

The test suite includes both unit tests with synthetic PDFs and validation tests against real PDF files.

To run unit tests:

```bash
swift run SwiftPDFTests
```

To run with real PDF files, create a `Sources/TestFiles/` directory and add `.pdf` files to it. The tests will validate that SwiftPDF produces the correct page count and that each split page is a valid PDF.

```bash
mkdir -p Sources/TestFiles
cp ~/some-pdfs/*.pdf Sources/TestFiles/
swift run SwiftPDFTests
```

## License

MIT
