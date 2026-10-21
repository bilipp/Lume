import Foundation
@testable import Lume
import Testing

@MainActor
struct CastServiceTests {
    typealias RouteOutput = CastService.RouteOutput

    @Test func `no outputs means no AirPlay route`() {
        #expect(CastService.activeAirPlayName(in: []) == nil)
    }

    @Test func `non-AirPlay outputs are ignored`() {
        let outputs = [
            RouteOutput(isAirPlay: false, name: "Speaker"),
            RouteOutput(isAirPlay: false, name: "Headphones")
        ]
        #expect(CastService.activeAirPlayName(in: outputs) == nil)
    }

    @Test func `an AirPlay output reports its name`() {
        let outputs = [RouteOutput(isAirPlay: true, name: "Living Room")]
        #expect(CastService.activeAirPlayName(in: outputs) == "Living Room")
    }

    @Test func `the first AirPlay output wins among a mixed route`() {
        let outputs = [
            RouteOutput(isAirPlay: false, name: "Speaker"),
            RouteOutput(isAirPlay: true, name: "Apple TV"),
            RouteOutput(isAirPlay: true, name: "Bedroom")
        ]
        #expect(CastService.activeAirPlayName(in: outputs) == "Apple TV")
    }

    @Test func `an AirPlay route without screen capture is a cast`() {
        #expect(CastService.isAirPlayCasting(routeName: "Apple TV", isScreenCaptured: false))
    }

    @Test func `screen mirroring over AirPlay is not a cast`() {
        #expect(!CastService.isAirPlayCasting(routeName: "Apple TV", isScreenCaptured: true))
    }

    @Test func `no AirPlay route is never a cast`() {
        #expect(!CastService.isAirPlayCasting(routeName: nil, isScreenCaptured: false))
        #expect(!CastService.isAirPlayCasting(routeName: nil, isScreenCaptured: true))
    }

    @Test func `shared service starts without a cast provider`() {
        // The Chromecast seam is empty until the Google Cast SDK is integrated.
        #expect(CastService.shared.castProvider == nil)
    }
}
