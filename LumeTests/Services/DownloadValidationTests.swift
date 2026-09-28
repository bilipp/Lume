import Foundation
@testable import Lume
import Testing

struct DownloadValidationTests {
    @Test func `accepts nonempty opaque media from a successful response`() throws {
        let fixture = try Fixture(data: Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]))
        defer { fixture.remove() }

        try DownloadValidator.validate(
            fileAt: fixture.file,
            response: response(status: 200, contentType: "application/octet-stream")
        )
    }

    @Test func `rejects unsuccessful HTTP response`() throws {
        let fixture = try Fixture(data: Data("Unauthorized".utf8))
        defer { fixture.remove() }

        #expect(throws: DownloadValidationError.httpStatus(401)) {
            try DownloadValidator.validate(
                fileAt: fixture.file,
                response: response(status: 401, contentType: "text/plain")
            )
        }
    }

    @Test func `rejects an empty file`() throws {
        let fixture = try Fixture(data: Data())
        defer { fixture.remove() }

        #expect(throws: DownloadValidationError.emptyFile) {
            try DownloadValidator.validate(fileAt: fixture.file, response: response(status: 200))
        }
        #expect(!DownloadValidator.isUsableFile(at: fixture.file))
    }

    @Test(arguments: [
        ("application/json", #"{"error":"expired"}"#),
        ("text/html", "<html><body>Login</body></html>"),
        ("application/vnd.apple.mpegurl", "#EXTM3U\n#EXT-X-VERSION:3")
    ])
    func `rejects nonmedia response documents`(contentType: String, body: String) throws {
        let fixture = try Fixture(data: Data(body.utf8))
        defer { fixture.remove() }

        #expect(throws: (any Error).self) {
            try DownloadValidator.validate(
                fileAt: fixture.file,
                response: response(status: 200, contentType: contentType)
            )
        }
    }

    @Test func `rejects an obvious provider error when MIME type lies`() throws {
        let fixture = try Fixture(data: Data(#"{"error":"not_allowed"}"#.utf8))
        defer { fixture.remove() }

        #expect(throws: DownloadValidationError.unsupportedPayload) {
            try DownloadValidator.validate(
                fileAt: fixture.file,
                response: response(status: 200, contentType: "application/octet-stream")
            )
        }
    }
}

private extension DownloadValidationTests {
    struct Fixture {
        let directory: URL
        let file: URL

        init(data: Data) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DownloadValidationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent("download.bin")
            try data.write(to: file)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func response(status: Int, contentType: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return HTTPURLResponse(
            url: URL(string: "https://provider.example/media/1")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
