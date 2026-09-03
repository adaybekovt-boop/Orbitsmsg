import Compression
import Foundation

/// Minimal ZIP extractor for the packaged worklet module archive.
/// Supports STORED and DEFLATE local-file entries produced by `zip -qr`.
enum ZipExtract {
  static func unzip(data: Data, into dest: URL) throws {
    let bytes = [UInt8](data)
    var offset = 0
    let fm = FileManager.default

    let maxEntries = 10_000
    let maxSingleFileSize = 50 * 1024 * 1024
    let maxTotalSize = 150 * 1024 * 1024

    var entryCount = 0
    var totalExpandedSize = 0
    var seenEntries = Set<String>()

    let tempDir = fm.temporaryDirectory.appendingPathComponent("worklet-unzip-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let destCanonical = dest.standardizedFileURL.path

    while offset + 30 <= bytes.count {
      let sig = readU32(bytes, offset)
      if sig == 0x02014B50 || sig == 0x06054B50 {
        break
      }
      guard sig == 0x04034B50 else {
        throw HostError.workletFailed
      }
      entryCount += 1
      if entryCount > maxEntries {
        throw HostError.workletFailed
      }

      let method = Int(readU16(bytes, offset + 8))
      let compSize = Int(readU32(bytes, offset + 18))
      let uncompSize = Int(readU32(bytes, offset + 22))
      let nameLen = Int(readU16(bytes, offset + 26))
      let extraLen = Int(readU16(bytes, offset + 28))
      let nameStart = offset + 30
      let nameEnd = nameStart + nameLen
      let dataStart = nameEnd + extraLen
      guard nameEnd <= bytes.count, dataStart + compSize <= bytes.count else {
        throw HostError.workletFailed
      }
      let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
      offset = dataStart + compSize

      // F-06: Never extract Mach-O binaries (.bare / .dylib / .node / .so) into writable storage
      if name.hasSuffix(".bare") || name.hasSuffix(".dylib") || name.hasSuffix(".so") || name.hasSuffix(".node") {
        continue
      }

      // F-23: Segment-level path traversal validation
      if name.isEmpty ||
        name.contains("\0") ||
        name.hasPrefix("/") ||
        name.hasPrefix("\\") ||
        name.contains(":") ||
        name.split(separator: "/").contains("..") ||
        name.split(separator: "\\").contains("..") {
        throw HostError.workletFailed
      }

      if !seenEntries.insert(name).inserted {
        throw HostError.workletFailed
      }

      if uncompSize > maxSingleFileSize {
        throw HostError.workletFailed
      }

      let outURL = tempDir.appendingPathComponent(name)
      let canonicalOut = outURL.standardizedFileURL.path
      guard canonicalOut.hasPrefix(tempDir.standardizedFileURL.path + "/") || canonicalOut == tempDir.standardizedFileURL.path else {
        throw HostError.workletFailed
      }

      if name.hasSuffix("/") {
        try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
        continue
      }

      let payload = Data(bytes[dataStart..<(dataStart + compSize)])
      let out: Data
      if method == 0 {
        out = payload
      } else if method == 8 {
        guard let inflated = inflate(payload, uncompressedSize: max(uncompSize, 1)) else {
          throw HostError.workletFailed
        }
        out = inflated
      } else {
        throw HostError.workletFailed
      }

      totalExpandedSize += out.count
      if totalExpandedSize > maxTotalSize {
        throw HostError.workletFailed
      }

      try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try out.write(to: outURL, options: .atomic)
    }

    // Atomically copy extracted files into destination
    if let items = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
      for item in items {
        let target = dest.appendingPathComponent(item.lastPathComponent)
        try? fm.removeItem(at: target)
        try fm.copyItem(at: item, to: target)
      }
    }
  }

  private static func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
    if let raw = decode(data, uncompressedSize: uncompressedSize) {
      return raw
    }
    var wrapped = Data([0x78, 0x9C])
    wrapped.append(data)
    return decode(wrapped, uncompressedSize: uncompressedSize)
  }

  private static func decode(_ data: Data, uncompressedSize: Int) -> Data? {
    var dest = Data(count: uncompressedSize)
    let written = dest.withUnsafeMutableBytes { destPtr -> Int in
      data.withUnsafeBytes { srcPtr -> Int in
        guard
          let dst = destPtr.bindMemory(to: UInt8.self).baseAddress,
          let src = srcPtr.bindMemory(to: UInt8.self).baseAddress
        else { return 0 }
        return compression_decode_buffer(
          dst,
          uncompressedSize,
          src,
          data.count,
          nil,
          COMPRESSION_ZLIB
        )
      }
    }
    return written > 0 ? dest.prefix(written) : nil
  }
}

private func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
  UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  UInt32(bytes[offset])
    | (UInt32(bytes[offset + 1]) << 8)
    | (UInt32(bytes[offset + 2]) << 16)
    | (UInt32(bytes[offset + 3]) << 24)
}
