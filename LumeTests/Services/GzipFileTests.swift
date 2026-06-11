//
//  GzipFileTests.swift
//  LumeTests
//

import Compression
import Foundation
@testable import Lume
import Testing

struct GzipFileTests {
    /// Builds a minimal gzip file: 10-byte header + raw deflate + 8-byte
    /// trailer (CRC/size — ignored by the decompressor, zeros suffice).
    private func gzip(_ payload: Data, flags: UInt8 = 0, name: String? = nil) -> Data {
        var data = Data([0x1F, 0x8B, 0x08, flags, 0, 0, 0, 0, 0, 0x03])
        if let name {
            data.append(Data(name.utf8))
            data.append(0)
        }

        let deflated = payload.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            let dstCapacity = payload.count + 1024
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dst.deallocate() }
            let written = compression_encode_buffer(
                dst, dstCapacity,
                src.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                nil, COMPRESSION_ZLIB
            )
            return Data(bytes: dst, count: written)
        }
        data.append(deflated)
        data.append(Data(count: 8)) // CRC32 + ISIZE, unchecked
        return data
    }

    @Test func `detects and decompresses gzip files`() throws {
        let payload = Data(String(repeating: "<programme channel=\"a\">guide</programme>\n", count: 50000).utf8)
        let gzipped = gzip(payload, flags: 0x08, name: "guide.xml")

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xml.gz")
        try gzipped.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(GzipFile.isGzip(source))

        let decompressed = try GzipFile.decompress(source)
        defer { try? FileManager.default.removeItem(at: decompressed) }
        #expect(try Data(contentsOf: decompressed) == payload)
    }

    @Test func `plain files are not gzip`() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xml")
        try Data("<tv></tv>".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(!GzipFile.isGzip(source))
    }

    @Test func `malformed gzip throws`() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".gz")
        try Data([0x1F, 0x8B, 0x07, 0, 0]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(throws: GzipFile.GzipError.self) {
            _ = try GzipFile.decompress(source)
        }
    }
}
