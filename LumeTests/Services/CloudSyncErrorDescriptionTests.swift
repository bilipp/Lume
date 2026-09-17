//
//  CloudSyncErrorDescriptionTests.swift
//  LumeTests
//
//  Guards the CloudKit error renderer: a `partialFailure` with no per-record
//  errors must still name its domain, code and underlying chain in the log, and
//  the settings row must show a cause rather than "CKErrorDomain error 2" (#156)
//  — without letting the added detail carry playlist credentials into an
//  exported diagnostic report.
//

import CloudKit
import Foundation
@testable import Lume
import Testing

struct CloudSyncErrorDescriptionTests {
    // MARK: - Fixtures

    private func ckError(
        _ code: CKError.Code,
        message: String = "The operation couldn’t be completed.",
        underlying: Error? = nil,
        partialErrors: [CKRecord.ID: Error]? = nil
    ) -> Error {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
        if let underlying {
            userInfo[NSUnderlyingErrorKey] = underlying as NSError
        }
        if let partialErrors {
            userInfo[CKPartialErrorsByItemIDKey] = partialErrors
        }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    // MARK: - Log detail

    @Test func `log detail names domain code and CKError case`() {
        let detail = CloudSyncErrorDescription.logDetail(for: ckError(.quotaExceeded, message: "Quota exceeded"))
        #expect(detail == "CKErrorDomain \(CKError.Code.quotaExceeded.rawValue) (quotaExceeded): Quota exceeded")
    }

    @Test func `code names line up with the real CKError values`() {
        // The name table is keyed by raw value, so a mis-keyed row would silently
        // mislabel a code — exactly the confusion this is meant to end.
        let expected: [(CKError.Code, String)] = [
            (.internalError, "internalError"),
            (.partialFailure, "partialFailure"),
            (.networkUnavailable, "networkUnavailable"),
            (.networkFailure, "networkFailure"),
            (.serviceUnavailable, "serviceUnavailable"),
            (.requestRateLimited, "requestRateLimited"),
            (.notAuthenticated, "notAuthenticated"),
            (.permissionFailure, "permissionFailure"),
            (.serverRecordChanged, "serverRecordChanged"),
            (.changeTokenExpired, "changeTokenExpired"),
            (.zoneBusy, "zoneBusy"),
            (.quotaExceeded, "quotaExceeded"),
            (.zoneNotFound, "zoneNotFound"),
            (.limitExceeded, "limitExceeded"),
            (.userDeletedZone, "userDeletedZone"),
            (.managedAccountRestricted, "managedAccountRestricted"),
            (.accountTemporarilyUnavailable, "accountTemporarilyUnavailable")
        ]
        for (code, name) in expected {
            let detail = CloudSyncErrorDescription.logDetail(for: ckError(code, message: "x"))
            #expect(detail.contains("(\(name))"), "code \(code.rawValue) rendered as \(detail)")
        }
    }

    @Test func `log detail flags a partial failure with no per record errors`() {
        // The motivating case: nothing to unwrap, so the emptiness itself has to
        // reach the log — it rules out a per-record rejection.
        let detail = CloudSyncErrorDescription.logDetail(for: ckError(.partialFailure, message: "Failed to modify some records"))
        #expect(detail == "CKErrorDomain 2 (partialFailure) [no per-record errors]: Failed to modify some records")
    }

    @Test func `log detail does not flag a partial failure that has per record errors`() {
        let error = ckError(
            .partialFailure,
            message: "Failed to modify some records",
            partialErrors: [CKRecord.ID(recordName: "abc"): ckError(.serverRecordChanged, message: "Conflict")]
        )
        #expect(!CloudSyncErrorDescription.logDetail(for: error).contains("no per-record errors"))
    }

    @Test func `log detail walks the underlying error chain`() {
        let root = NSError(domain: "NSPOSIXErrorDomain", code: 50, userInfo: [NSLocalizedDescriptionKey: "Network is down"])
        let middle = NSError(
            domain: NSCocoaErrorDomain,
            code: 4097,
            userInfo: [NSLocalizedDescriptionKey: "Connection interrupted", NSUnderlyingErrorKey: root]
        )
        let detail = CloudSyncErrorDescription.logDetail(for: ckError(.partialFailure, underlying: middle))
        #expect(detail.contains("CKErrorDomain 2 (partialFailure)"))
        #expect(detail.contains("NSCocoaErrorDomain 4097: Connection interrupted"))
        #expect(detail.contains("NSPOSIXErrorDomain 50: Network is down"))
    }

    @Test func `log detail scrubs credentials out of every link`() {
        let root = NSError(
            domain: "TestDomain",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "rejected http://iptv.example.com/live/myuser/mypass/1.ts"]
        )
        let detail = CloudSyncErrorDescription.logDetail(
            for: ckError(.partialFailure, message: "push to https://portal.example.com/c/?mac=00:1A:79:AA failed", underlying: root)
        )
        #expect(!detail.contains("myuser"))
        #expect(!detail.contains("mypass"))
        #expect(!detail.contains("00:1A:79:AA"))
        #expect(detail.contains("http://<redacted>"))
        #expect(detail.contains("https://<redacted>"))
    }

    @Test func `log detail caps a pathologically deep chain`() {
        var error = NSError(domain: "TestDomain", code: 0, userInfo: [NSLocalizedDescriptionKey: "root"])
        for depth in 1 ... 6 {
            error = NSError(
                domain: "TestDomain",
                code: depth,
                userInfo: [NSLocalizedDescriptionKey: "level \(depth)", NSUnderlyingErrorKey: error]
            )
        }
        #expect(CloudSyncErrorDescription.logDetail(for: error).components(separatedBy: " ← ").count == 4)
    }

    // MARK: - CKError extraction

    @Test func `finds a CKError wrapped two levels deep`() {
        let inner = ckError(.zoneBusy)
        let middle = NSError(domain: NSCocoaErrorDomain, code: 134_400, userInfo: [NSUnderlyingErrorKey: inner as NSError])
        let outer = NSError(domain: NSCocoaErrorDomain, code: 4097, userInfo: [NSUnderlyingErrorKey: middle])
        #expect(CloudSyncErrorDescription.ckError(in: outer)?.code == .zoneBusy)
    }

    @Test func `reports no CKError when the chain has none`() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4097, userInfo: [:])
        #expect(CloudSyncErrorDescription.ckError(in: error) == nil)
    }

    // MARK: - User-facing message

    @Test func `maps the common CKError codes to a cause`() {
        let mapped: [CKError.Code] = [
            .quotaExceeded, .networkUnavailable, .networkFailure, .notAuthenticated,
            .zoneBusy, .serverRecordChanged, .partialFailure
        ]
        for code in mapped {
            let message = CloudSyncErrorDescription.message(for: ckError(code))
            #expect(!message.contains("CKErrorDomain"), "\(code) still surfaced the raw domain")
            #expect(!message.contains("\(code.rawValue)"), "\(code) still surfaced the raw code")
            #expect(message.count > 20, "\(code) produced no explanatory text")
        }
    }

    @Test func `maps a CKError reached only through the underlying chain`() {
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: 4097,
            userInfo: [NSUnderlyingErrorKey: ckError(.quotaExceeded) as NSError]
        )
        #expect(CloudSyncErrorDescription.message(for: wrapped) == CloudSyncErrorDescription.message(for: ckError(.quotaExceeded)))
    }

    @Test func `an unmapped CKError still names its case`() {
        let message = CloudSyncErrorDescription.message(for: ckError(.internalError, message: "Something went wrong."))
        #expect(message == "Something went wrong. (internalError)")
    }

    @Test func `a non CloudKit error keeps its own description`() {
        let error = NSError(domain: "TestDomain", code: 3, userInfo: [NSLocalizedDescriptionKey: "Local save failed"])
        #expect(CloudSyncErrorDescription.message(for: error) == "Local save failed")
    }
}
