import Foundation

/// Output image format for PDF page rendering.
public enum ImageFormat: Sendable {
  /// PNG (lossless, larger files)
  case png
  /// JPEG with quality 1–100 (lossy, smaller files)
  case jpeg(quality: Int = 85)

  var fileExtension: String {
    switch self {
    case .png: "png"
    case .jpeg: "jpg"
    }
  }

  /// vips output suffix including save options (e.g. `[Q=85]` for JPEG)
  func vipsSuffix(for path: String) -> String {
    switch self {
    case .png:
      return path
    case .jpeg(let quality):
      return "\(path)[Q=\(quality)]"
    }
  }
}

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

  func renderPage(pdfPath: String, pageIndex: Int, outputPath: String, dpi: Double, format: ImageFormat = .png) throws {
    let vipsURL = try resolveVips()
    let process = Process()
    process.executableURL = vipsURL
    process.arguments = [
      "copy",
      "\(pdfPath)[dpi=\(dpi),page=\(pageIndex)]",
      format.vipsSuffix(for: outputPath),
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
