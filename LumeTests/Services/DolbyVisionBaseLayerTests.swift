@testable import Lume
import Testing

/// Which Dolby Vision streams the player hands to LumeEngine: only those whose
/// base layer is IPT, which every other engine renders pink/green.
struct DolbyVisionBaseLayerTests {
    @Test func `profiles 5, 20 and 10.0 carry an IPT base layer`() {
        #expect(DolbyVisionBaseLayer.isIPT(profile: 5, compatibilityID: 0))
        #expect(DolbyVisionBaseLayer.isIPT(profile: 20, compatibilityID: 0))
        #expect(DolbyVisionBaseLayer.isIPT(profile: 10, compatibilityID: 0))
    }

    @Test func `cross-compatible base layers stay on the user's engine`() {
        #expect(!DolbyVisionBaseLayer.isIPT(profile: 8, compatibilityID: 1))
        #expect(!DolbyVisionBaseLayer.isIPT(profile: 8, compatibilityID: 4))
        #expect(!DolbyVisionBaseLayer.isIPT(profile: 10, compatibilityID: 1))
    }

    @Test func `dual-layer profiles are not IPT even with compatibility id 0`() {
        #expect(!DolbyVisionBaseLayer.isIPT(profile: 4, compatibilityID: 0))
        #expect(!DolbyVisionBaseLayer.isIPT(profile: 7, compatibilityID: 0))
    }
}
