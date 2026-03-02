import Foundation

struct PDFRenderer: Sendable {
  private static let searchPaths = [
    "/opt/homebrew/bin/vips",  // macOS Apple Silicon (Homebrew)
    "/usr/local/bin/vips",     // macOS Intel (Homebrew) / Linux manual install
    "/usr/bin/vips",           // Linux system package
  ]

  private func findVips() -> String? {
    // Check explicit paths first (works even with minimal PATH)
    for path in Self.searchPaths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }
    // Fall back to PATH lookup via `which`
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", "vips"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = output, !path.isEmpty {
          return path
        }
      }
    } catch {}
    return nil
  }

  private func resolveVips() throws -> URL {
    guard let path = findVips() else {
      throw PDFError.renderError(
        "vips not found. Install with: brew install vips (macOS) or apt install libvips-tools (Linux)"
      )
    }
    return URL(fileURLWithPath: path)
  }

  func validateVips() throws {
    let vipsURL = try resolveVips()
    let process = Process()
    process.executableURL = vipsURL
    process.arguments = ["--version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      throw PDFError.renderError("Failed to run vips at \(vipsURL.path): \(error.localizedDescription)")
    }
    guard process.terminationStatus == 0 else {
      throw PDFError.renderError("vips at \(vipsURL.path) exited with code \(process.terminationStatus)")
    }
  }

  func renderPage(pdfPath: String, pageIndex: Int, outputPath: String, dpi: Double) throws {
    let vipsURL = try resolveVips()
    let process = Process()
    process.executableURL = vipsURL
    process.arguments = [
      "copy",
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
