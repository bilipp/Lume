//
//  LumeCloudVectorExportTests.swift
//  LumeTests
//
//  The cross-platform vectors in `../LumeCloud/spec/vectors` (identity.json,
//  merge.json, payloads/*.json), generated from the app's real helpers so the
//  Apple app stays the reference implementation Android is checked against.
//
//  By default every test regenerates its document and compares it byte for
//  byte with the committed file, so a change to a helper that would re-key
//  user state on the other platform fails here first. Regenerate after an
//  intentional change with:
//
//      xcodebuild test … -only-testing:LumeTests/LumeCloudVectorExportTests
//      with TEST_RUNNER_LUME_EXPORT_VECTORS=1 in the environment
//
//  The suite skips when the LumeCloud sibling checkout is absent.
//

import Foundation
@testable import Lume
import LumeCloudKit
import SwiftData
import Testing

nonisolated enum LumeCloudVectorFiles {
    static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LumeTests
        .deletingLastPathComponent() // repo root
        .deletingLastPathComponent() // the sibling checkouts' parent
        .appending(path: "LumeCloud/spec/vectors")

    static var siblingExists: Bool {
        FileManager.default.fileExists(atPath: vectorsURL.deletingLastPathComponent().path)
    }

    static var isExporting: Bool {
        ProcessInfo.processInfo.environment["LUME_EXPORT_VECTORS"] == "1"
    }

    /// Same formatting as the Kit's `crypto.json`.
    static func encode(_ document: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// Writes `data` when exporting; otherwise requires the committed file to
    /// hold exactly these bytes.
    static func exportOrCheck(_ data: Data, at relativePath: String) throws {
        let url = vectorsURL.appending(path: relativePath)
        if isExporting {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return
        }
        let committed = try #require(
            try? Data(contentsOf: url),
            "\(relativePath) is missing — regenerate with TEST_RUNNER_LUME_EXPORT_VECTORS=1"
        )
        #expect(
            committed == data,
            "\(relativePath) drifted from the app's helpers — regenerate with TEST_RUNNER_LUME_EXPORT_VECTORS=1 if the change is intended"
        )
    }

    /// A canonical payload's bytes as a JSON value, for the readable copies.
    static func json(_ bytes: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: bytes)
    }

    /// An `Encodable` merge value in wire form: epoch-millisecond dates,
    /// uppercase UUIDs, absent optionals.
    static func json(encoding value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
}

@MainActor
@Suite(.serialized, .enabled(if: LumeCloudVectorFiles.siblingExists))
struct LumeCloudVectorExportTests {
    typealias Files = LumeCloudVectorFiles

    /// The fixed playlist every composed catalog id starts with.
    static let playlistID = UUID(uuidString: "0A1B2C3D-0000-4000-8000-00000000AB01")!
    static let profileID = UUID(uuidString: "6F1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    /// The root key of `crypto.json` (bytes 0x00…0x1f), so every `rid` here can
    /// be checked against the same derived keys.
    static let rootKey = Data(0 ..< 32)

    static func date(_ milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// The mirror models need a loaded schema even while uninserted.
    let container: ModelContainer

    init() throws {
        container = try LumeApp.makeLumeCloudContainer(isStoredInMemoryOnly: true)
    }

    @Test func `identity vectors match the catalog id helpers`() throws {
        try Files.exportOrCheck(Files.encode(Self.identityDocument()), at: "identity.json")
    }

    @Test func `merge vectors match the merge rules`() throws {
        try Files.exportOrCheck(Files.encode(Self.mergeDocument()), at: "merge.json")
    }

    @Test func `payload vectors match the codec`() throws {
        let documents = try Self.payloadDocuments(in: container.mainContext)
        let types = LumeCloudPayloadCodec.mappableModels.map { model in model.lumeCloudType }
        #expect(Set(documents.map(\.type)) == Set(types))
        for document in documents {
            try Files.exportOrCheck(Files.encode(document), at: "payloads/\(document.type).json")
        }
    }
}
