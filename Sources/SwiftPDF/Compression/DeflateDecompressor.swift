import CZlib
import Foundation

enum DeflateDecompressor {
  static func decompress(_ data: Data) throws -> Data {
    var stream = z_stream()
    stream.zalloc = nil
    stream.zfree = nil
    stream.opaque = nil

    // Use inflateInit2 with windowBits = 47 to auto-detect zlib/gzip/raw deflate
    let initResult = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int32 in
      guard let baseAddress = ptr.baseAddress else { return Z_DATA_ERROR }
      stream.next_in = UnsafeMutablePointer<UInt8>(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
      stream.avail_in = UInt32(data.count)
      return inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    guard initResult == Z_OK else {
      throw PDFError.decompressionError("inflateInit2 failed: \(initResult)")
    }

    defer { inflateEnd(&stream) }

    var output = Data()
    let bufferSize = 65536
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    repeat {
      stream.next_out = buffer.baseAddress
      stream.avail_out = UInt32(bufferSize)

      let result = inflate(&stream, Z_NO_FLUSH)

      switch result {
      case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
        let bytesProduced = bufferSize - Int(stream.avail_out)
        output.append(buffer.baseAddress!, count: bytesProduced)
        if result == Z_STREAM_END { return output }
      default:
        let msg = stream.msg.map { String(cString: $0) } ?? "unknown"
        throw PDFError.decompressionError("inflate failed: \(result) - \(msg)")
      }
    } while stream.avail_in > 0 || stream.avail_out == 0

    return output
  }
}
