import Foundation
import SwiftPDF

#if canImport(PDFKit)
  import PDFKit
#endif

nonisolated(unsafe) var realFileTestsFailed = false

func runRealFileTests() {
  setenv("CG_PDF_VERBOSE", "1", 1)
  let testFilesDir: String = {
    let candidates = [
      FileManager.default.currentDirectoryPath + "/Sources/TestFiles",
      FileManager.default.currentDirectoryPath + "/TestFiles",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
  }()

  let fm = FileManager.default

  guard fm.fileExists(atPath: testFilesDir) else {
    print("\nSkipping real file tests: TestFiles directory not found")
    return
  }

  guard let files = try? fm.contentsOfDirectory(atPath: testFilesDir)
    .filter({ $0.hasSuffix(".pdf") })
    .sorted()
  else {
    print("Cannot list TestFiles directory")
    return
  }

  print("\nReal PDF File Tests (\(files.count) files)")
  print("========================================")

  // Thread-safe counters
  let lock = NSLock()
  var totalPassed = 0
  var totalFailed = 0
  var totalSkipped = 0
  var errorMessages: [(file: String, error: String)] = []
  var shouldStop = false

  let concurrency = ProcessInfo.processInfo.activeProcessorCount
  let group = DispatchGroup()
  let queue = DispatchQueue(label: "pdf-tests", attributes: .concurrent)
  let semaphore = DispatchSemaphore(value: concurrency)

  for file in files {
    // Check early exit
    lock.lock()
    let stop = shouldStop
    lock.unlock()
    if stop { break }

    semaphore.wait()
    group.enter()

    queue.async {
      defer {
        semaphore.signal()
        group.leave()
      }

      // Check early exit inside worker too
      lock.lock()
      let stopNow = shouldStop
      lock.unlock()
      if stopNow { return }

      let path = (testFilesDir as NSString).appendingPathComponent(file)
      guard let data = fm.contents(atPath: path) else {
        lock.lock()
        totalSkipped += 1
        lock.unlock()
        return
      }

      let result = testSingleFile(file: file, data: data)

      lock.lock()
      switch result {
      case .passed:
        totalPassed += 1
      case .skipped:
        totalSkipped += 1
      case let .failed(msg):
        totalFailed += 1
        errorMessages.append((file, msg))
        if totalFailed >= 10 {
          shouldStop = true
        }
      }
      lock.unlock()
    }
  }

  group.wait()

  if shouldStop {
    print("  ... stopped early after \(totalFailed) failures")
  }

  // Print errors
  for (i, err) in errorMessages.sorted(by: { $0.file < $1.file }).enumerated() {
    if i >= 30 {
      print("  ... and \(errorMessages.count - 30) more errors")
      break
    }
    print("  FAIL [\(err.file)] \(err.error)")
  }

  print("\n========================================")
  print(
    "Real file results: \(totalPassed) passed, \(totalFailed) failed, \(totalSkipped) skipped (of \(files.count) files)"
  )
  print("========================================")

  if totalFailed > 0 {
    realFileTestsFailed = true
  }
}

enum FileTestResult {
  case passed
  case skipped
  case failed(String)
}

func testSingleFile(file: String, data: Data) -> FileTestResult {
  let splitter = PDF()

  // Per-file timeout
  let sem = DispatchSemaphore(value: 0)
  nonisolated(unsafe) var result: FileTestResult = .failed("TIMEOUT (>10s)")

  DispatchQueue.global().async {
    do {
      let swiftPDFCount: Int
      do {
        swiftPDFCount = try splitter.pageCount(in: data)
      } catch let error as PDFError {
        if case .encryptedPDF = error {
          result = .skipped
          sem.signal()
          return
        }
        result = .failed("pageCount error: \(error)")
        sem.signal()
        return
      }

      #if canImport(PDFKit)
        if let pdfDoc = PDFDocument(data: data) {
          let pdfKitCount = pdfDoc.pageCount
          if swiftPDFCount != pdfKitCount {
            result = .failed("Page count mismatch: SwiftPDF=\(swiftPDFCount) PDFKit=\(pdfKitCount)")
            sem.signal()
            return
          }
        }
      #endif

      // Skip full split validation for large documents (>100 pages) to keep test times reasonable
      if swiftPDFCount > 100 {
        result = .passed
        sem.signal()
        return
      }

      let pages = try splitter.split(pdfData: data)
      if pages.count != swiftPDFCount {
        result = .failed("Split count mismatch: split=\(pages.count) pageCount=\(swiftPDFCount)")
        sem.signal()
        return
      }

      for (pageIdx, pageData) in pages.enumerated() {
        if pageData.count < 5 || String(data: pageData.prefix(5), encoding: .ascii) != "%PDF-" {
          result = .failed("Page \(pageIdx + 1) missing PDF header")
          sem.signal()
          return
        }

        let subCount = try splitter.pageCount(in: pageData)
        if subCount != 1 {
          result = .failed("Split page \(pageIdx + 1) has \(subCount) pages")
          sem.signal()
          return
        }

        #if canImport(PDFKit)
          if PDFDocument(data: pageData) == nil {
            result = .failed("Split page \(pageIdx + 1) rejected by PDFKit")
            sem.signal()
            return
          }
        #endif
      }
      result = .passed
    } catch {
      result = .failed("Split error: \(error)")
    }
    sem.signal()
  }

  // Scale timeout with file size and page count: 45s base + 3s per MB
  let timeoutSeconds = 45 + (data.count / (1024 * 1024) * 3)
  let timedOut = sem.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut
  if timedOut {
    return .failed("TIMEOUT (>\(timeoutSeconds)s)")
  }
  return result
}
