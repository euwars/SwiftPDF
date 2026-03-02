import Foundation

struct PDFRenderer: Sendable {
  func validateVips() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["vips", "--version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw PDFError.renderError("vips not found. Install with: brew install vips (macOS) or apt install libvips-tools (Linux)")
    }
    guard process.terminationStatus == 0 else {
      throw PDFError.renderError("vips not found. Install with: brew install vips (macOS) or apt install libvips-tools (Linux)")
    }
  }

  func renderPage(pdfPath: String, pageIndex: Int, outputPath: String, dpi: Double) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "vips", "copy",
      "\(pdfPath)[dpi=\(dpi),page=\(pageIndex)]",
      outputPath,
    ]
    let errorPipe = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw PDFError.renderError("Failed to launch vips: \(error.localizedDescription)")
    }
    guard process.terminationStatus == 0 else {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
      throw PDFError.renderError("vips failed (exit \(process.terminationStatus)): \(errorMessage)")
    }
  }
}
