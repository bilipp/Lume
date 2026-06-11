//
//  GzipFile.swift
//  Lume
//
//  Streaming gunzip for downloaded files. Public XMLTV guides are commonly
//  served as `.xml.gz` (and not with Content-Encoding, so URLSession doesn't
//  inflate them) — this decompresses file-to-file in fixed-size chunks via the
//  Compression framework, so a multi-hundred-megabyte guide never lives in
//  memory as one blob.
//

import Compression
import Foundation

nonisolated enum GzipFile {
    /// True when the file starts with the gzip magic bytes.
    static func isGzip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 2)) ?? Data()
        return magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
    }

    enum GzipError: Error {
        case malformedHeader
        case decompressionFailed
    }

    /// Decompresses a gzip file into a new temp file and returns its URL.
    /// The gzip wrapper (header + CRC trailer) is stripped manually because
    /// `Compression`'s zlib codec handles only the raw deflate stream inside.
    static func decompress(_ source: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        // Read an initial chunk and skip the gzip header within it. Headers
        // are tiny (10 bytes + optional name/extra fields); a 64 KB first read
        // covers any realistic header.
        var pending = (try? input.read(upToCount: 64 * 1024)) ?? Data()
        let headerLength = try gzipHeaderLength(pending)
        pending.removeFirst(headerLength)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xml")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        try inflate(deflateHead: pending, input: input, output: output)
        return destination
    }

    /// Runs the raw deflate stream (the gzip body) through the Compression
    /// framework chunk by chunk, writing inflated bytes to `output`.
    private static func inflate(deflateHead: Data, input: FileHandle, output: FileHandle) throws {
        var pending = deflateHead
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.decompressionFailed
        }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 256 * 1024
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dstBuffer.deallocate() }

        var finished = false
        while !finished {
            if pending.isEmpty {
                pending = (try? input.read(upToCount: bufferSize)) ?? Data()
            }
            let isLastChunk = pending.isEmpty

            try pending.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
                streamPointer.pointee.src_ptr = srcRaw.bindMemory(to: UInt8.self).baseAddress
                    ?? UnsafePointer<UInt8>(bitPattern: 1)!
                streamPointer.pointee.src_size = srcRaw.count

                repeat {
                    streamPointer.pointee.dst_ptr = dstBuffer
                    streamPointer.pointee.dst_size = bufferSize
                    let status = compression_stream_process(
                        streamPointer, isLastChunk ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    )
                    switch status {
                    case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                        let produced = bufferSize - streamPointer.pointee.dst_size
                        if produced > 0 {
                            output.write(Data(bytes: dstBuffer, count: produced))
                        }
                        if status == COMPRESSION_STATUS_END {
                            finished = true
                        }
                    default:
                        throw GzipError.decompressionFailed
                    }
                    // Keep draining while the decoder fills the whole buffer.
                } while !finished && streamPointer.pointee.dst_size == 0
            }
            pending = Data()
        }
    }

    /// Length of the gzip member header at the start of `data`.
    private static func gzipHeaderLength(_ data: Data) throws -> Int {
        let bytes = [UInt8](data.prefix(1024))
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw GzipError.malformedHeader
        }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count >= index + 2 else { throw GzipError.malformedHeader }
            let extraLength = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2 + extraLength
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 { // FNAME, FCOMMENT
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            index += 1 // trailing NUL
        }
        if flags & 0x02 != 0 { // FHCRC
            index += 2
        }
        guard index <= bytes.count else { throw GzipError.malformedHeader }
        return index
    }
}
