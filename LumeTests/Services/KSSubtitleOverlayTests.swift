import Foundation
@testable import Lume
import Testing

/// Guards the per-cue rendering decision behind the KSPlayer subtitle fix
/// (issue #92): the engine decodes subtitle parts, and this choice decides what
/// each part draws. The regression was text cues producing no on-screen view,
/// so the key case is that a text-only cue maps to `.text`, never `.empty`.
struct KSSubtitleOverlayTests {
    @Test func `text-only cue renders as text`() {
        #expect(KSSubtitleCue(hasImage: false, hasText: true) == .text)
    }

    @Test func `bitmap cue renders as image`() {
        #expect(KSSubtitleCue(hasImage: true, hasText: false) == .image)
    }

    @Test func `image takes precedence over text`() {
        #expect(KSSubtitleCue(hasImage: true, hasText: true) == .image)
    }

    @Test func `cue with no content renders nothing`() {
        #expect(KSSubtitleCue(hasImage: false, hasText: false) == .empty)
    }
}
