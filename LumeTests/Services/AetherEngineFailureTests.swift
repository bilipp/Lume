@testable import Lume
import Testing

struct AetherEngineFailureTests {
    @Test func `a refusal is read from its HTTP status`() {
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: 401) == .unauthorized)
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: 403) == .unauthorized)
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: 404) == .notFound)
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: 410) == .notFound)
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: 502) == .overloaded)
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: 400) == .interrupted)
        #expect(AetherEngineFailure.classify(kind: "sourceRefused", code: nil) == .interrupted)
    }

    @Test func `a rate limit is an overloaded source whatever its status`() {
        #expect(AetherEngineFailure.classify(kind: "sourceRateLimited", code: 509) == .overloaded)
        #expect(AetherEngineFailure.classify(kind: "sourceRateLimited", code: nil) == .overloaded)
    }

    @Test func `media the engine cannot serve hands over to another engine`() {
        for kind in ["audioBridgeProducedNoOutput", "nativeItemFailed", "softwarePipelineFailed", "hlsFormatUnsupported"] {
            #expect(AetherEngineFailure.classify(kind: kind, code: nil) == .unsupported)
        }
    }

    @Test func `source loss and unknown kinds reconnect on the normal schedule`() {
        for kind in ["liveSourceUnavailable", "sourceOpenFailed", "vodSourceFailed", "storageExhausted", "", "someFutureKind"] {
            #expect(AetherEngineFailure.classify(kind: kind, code: 500) == .interrupted)
        }
    }
}
