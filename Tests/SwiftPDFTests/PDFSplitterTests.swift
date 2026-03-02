import Foundation
import SwiftPDF

@main
struct TestRunner {
  // Simple test harness
  nonisolated(unsafe) static var passed = 0
  nonisolated(unsafe) static var failed = 0

  static func check(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
      passed += 1
    } else {
      failed += 1
      print("  FAIL [\(file):\(line)] \(message)")
    }
  }

  static func assertThrows(_ expression: @autoclosure () throws -> some Any, _ message: String = "") {
    do {
      _ = try expression()
      failed += 1
      print("  FAIL: Expected error but succeeded. \(message)")
    } catch {
      passed += 1
    }
  }

  static func test(_ name: String, _ body: () throws -> Void) {
    print("Test: \(name)...", terminator: " ")
    do {
      try body()
      print("OK")
    } catch {
      failed += 1
      print("ERROR: \(error)")
    }
  }

  // MARK: - Test PDF Builder

  static func makeTestPDF() -> Data {
    var pdf = Data()
    func append(_ s: String) {
      pdf.append(contentsOf: s.utf8)
    }

    append("%PDF-1.4\n")

    let catalogOffset = pdf.count
    append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

    let pagesOffset = pdf.count
    append("2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 612 792] >>\nendobj\n")

    let page1Offset = pdf.count
    append("3 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 5 0 R /Resources << >> >>\nendobj\n")

    let page2Offset = pdf.count
    append("4 0 obj\n<< /Type /Page /Parent 2 0 R /Contents 6 0 R /Resources << >> >>\nendobj\n")

    let content1 = "BT /F1 24 Tf 100 700 Td (Page 1) Tj ET"
    let stream1Offset = pdf.count
    append("5 0 obj\n<< /Length \(content1.count) >>\nstream\n")
    append(content1)
    append("\nendstream\nendobj\n")

    let content2 = "BT /F1 24 Tf 100 700 Td (Page 2) Tj ET"
    let stream2Offset = pdf.count
    append("6 0 obj\n<< /Length \(content2.count) >>\nstream\n")
    append(content2)
    append("\nendstream\nendobj\n")

    let xrefOff = pdf.count
    append("xref\n")
    append("0 7\n")
    append(String(format: "%010d %05d f \n", 0, 65535))
    append(String(format: "%010d %05d n \n", catalogOffset, 0))
    append(String(format: "%010d %05d n \n", pagesOffset, 0))
    append(String(format: "%010d %05d n \n", page1Offset, 0))
    append(String(format: "%010d %05d n \n", page2Offset, 0))
    append(String(format: "%010d %05d n \n", stream1Offset, 0))
    append(String(format: "%010d %05d n \n", stream2Offset, 0))

    append("trailer\n<< /Size 7 /Root 1 0 R >>\n")
    append("startxref\n\(xrefOff)\n%%EOF\n")

    return pdf
  }

  static func main() {
    let splitter = PDF()

    test("pageCount") {
      let pdf = makeTestPDF()
      let count = try splitter.pageCount(in: pdf)
      check(count == 2, "Expected 2 pages, got \(count)")
    }

    test("splitReturnsCorrectNumberOfPages") {
      let pdf = makeTestPDF()
      let pages = try splitter.split(pdfData: pdf)
      check(pages.count == 2, "Expected 2 pages, got \(pages.count)")
    }

    test("eachPageIsValidPDF") {
      let pdf = makeTestPDF()
      let pages = try splitter.split(pdfData: pdf)

      for (i, pageData) in pages.enumerated() {
        let header = String(data: pageData.prefix(5), encoding: .ascii)
        check(header == "%PDF-", "Page \(i + 1) should have PDF header")

        let content = String(data: pageData, encoding: .isoLatin1) ?? ""
        check(content.contains("%%EOF"), "Page \(i + 1) should have EOF marker")

        let subCount = try splitter.pageCount(in: pageData)
        check(subCount == 1, "Extracted page \(i + 1) should contain 1 page, got \(subCount)")
      }
    }

    test("extractSinglePage") {
      let pdf = makeTestPDF()
      let page1 = try splitter.extractPage(from: pdf, at: 0)
      let page2 = try splitter.extractPage(from: pdf, at: 1)

      let count1 = try splitter.pageCount(in: page1)
      let count2 = try splitter.pageCount(in: page2)
      check(count1 == 1, "Page 1 should have 1 page, got \(count1)")
      check(count2 == 1, "Page 2 should have 1 page, got \(count2)")
    }

    test("invalidPageIndex") {
      let pdf = makeTestPDF()
      try assertThrows(splitter.extractPage(from: pdf, at: 5))
      try assertThrows(splitter.extractPage(from: pdf, at: -1))
    }

    test("invalidPDF") {
      let garbage = Data("not a pdf".utf8)
      try assertThrows(splitter.pageCount(in: garbage))
    }

    test("inheritedMediaBox") {
      let pdf = makeTestPDF()
      let pages = try splitter.split(pdfData: pdf)
      for (i, pageData) in pages.enumerated() {
        let content = String(data: pageData, encoding: .isoLatin1) ?? ""
        check(content.contains("MediaBox"), "Page \(i + 1) should have MediaBox")
      }
    }

    test("splitToFiles") {
      let pdf = makeTestPDF()
      let tempDir = NSTemporaryDirectory() + "SwiftPDFTest_\(UUID().uuidString)"
      let inputPath = tempDir + "/test.pdf"

      let fm = FileManager.default
      try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
      fm.createFile(atPath: inputPath, contents: pdf)

      defer { try? fm.removeItem(atPath: tempDir) }

      let outputDir = tempDir + "/output"
      let paths = try splitter.split(inputPath: inputPath, outputDirectory: outputDir)

      check(paths.count == 2, "Expected 2 output paths")
      for path in paths {
        check(fm.fileExists(atPath: path), "File should exist: \(path)")
      }
    }

    test("splitOutputRoundTrip") {
      let pdf = makeTestPDF()
      let pages = try splitter.split(pdfData: pdf)

      for (i, pageData) in pages.enumerated() {
        // Each split page should be readable as a standalone PDF
        let count = try splitter.pageCount(in: pageData)
        check(count == 1, "Split page \(i) should report 1 page, got \(count)")

        // Extracting page 0 from a single-page PDF should succeed
        let extracted = try splitter.extractPage(from: pageData, at: 0)
        let extractedCount = try splitter.pageCount(in: extracted)
        check(extractedCount == 1, "Re-extracted page \(i) should report 1 page, got \(extractedCount)")

        // Splitting a single-page PDF should return exactly one page
        let reSplit = try splitter.split(pdfData: pageData)
        check(reSplit.count == 1, "Re-splitting page \(i) should yield 1 page, got \(reSplit.count)")

        // That re-split page should also be readable
        let finalCount = try splitter.pageCount(in: reSplit[0])
        check(finalCount == 1, "Re-split output for page \(i) should report 1 page, got \(finalCount)")
      }
    }

    test("encryptedPDFDetection") {
      var pdf = Data()
      func append(_ s: String) {
        pdf.append(contentsOf: s.utf8)
      }

      append("%PDF-1.4\n")
      let catOff = pdf.count
      append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
      let pagesOff = pdf.count
      append("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")

      let xrefOff = pdf.count
      append("xref\n0 3\n")
      append(String(format: "%010d %05d f \n", 0, 65535))
      append(String(format: "%010d %05d n \n", catOff, 0))
      append(String(format: "%010d %05d n \n", pagesOff, 0))
      append("trailer\n<< /Size 3 /Root 1 0 R /Encrypt << /V 1 >> >>\n")
      append("startxref\n\(xrefOff)\n%%EOF\n")

      try assertThrows(splitter.pageCount(in: pdf), "Should throw for encrypted PDF")
    }

    // MARK: - Render Tests

    let vipsAvailable = isVipsAvailable()
    if vipsAvailable {
      test("renderSinglePage") {
        let pdf = makeTestPDF()
        let pngData = try splitter.renderPage(from: pdf, at: 0)
        // PNG magic bytes: 0x89 P N G
        check(pngData.count > 8, "PNG data should not be empty")
        check(
          pngData[0] == 0x89 && pngData[1] == 0x50 && pngData[2] == 0x4E && pngData[3] == 0x47,
          "Output should be a valid PNG (magic bytes)"
        )
      }

      test("renderSinglePageInvalidIndex") {
        let pdf = makeTestPDF()
        try assertThrows(splitter.renderPage(from: pdf, at: 99))
      }

      test("renderAllPages") {
        let pdf = makeTestPDF()
        let pngs = try splitter.renderPages(pdfData: pdf)
        check(pngs.count == 2, "Expected 2 PNGs, got \(pngs.count)")
        for (i, png) in pngs.enumerated() {
          check(
            png[0] == 0x89 && png[1] == 0x50,
            "Page \(i) should be a PNG"
          )
        }
      }

      test("renderToFiles") {
        let pdf = makeTestPDF()
        let tempDir = NSTemporaryDirectory() + "SwiftPDFRenderTest_\(UUID().uuidString)"
        let inputPath = tempDir + "/test.pdf"

        let fm = FileManager.default
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        fm.createFile(atPath: inputPath, contents: pdf)

        defer { try? fm.removeItem(atPath: tempDir) }

        let outputDir = tempDir + "/output"
        let paths = try splitter.renderPages(inputPath: inputPath, outputDirectory: outputDir)

        check(paths.count == 2, "Expected 2 output paths, got \(paths.count)")
        for path in paths {
          check(fm.fileExists(atPath: path), "PNG file should exist: \(path)")
          check(path.hasSuffix(".png"), "Output should be .png: \(path)")
          if let data = fm.contents(atPath: path) {
            check(data[0] == 0x89 && data[1] == 0x50, "File should be a PNG")
          } else {
            check(false, "Cannot read output file: \(path)")
          }
        }
      }

      test("renderCustomDPI") {
        let pdf = makeTestPDF()
        let png72 = try splitter.renderPage(from: pdf, at: 0, dpi: 72)
        let png300 = try splitter.renderPage(from: pdf, at: 0, dpi: 300)
        check(png300.count > png72.count, "300 DPI PNG should be larger than 72 DPI")
      }
    } else {
      print("\nSkipping render tests: vips not installed")
    }

    // MARK: - Summary

    print("\n========================================")
    print("Unit test results: \(passed) passed, \(failed) failed")
    print("========================================")

    // Run real file tests
    runRealFileTests()

    if failed > 0 || realFileTestsFailed {
      exit(1)
    }
  }

  static func isVipsAvailable() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["vips", "--version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }
}
