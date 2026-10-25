//
//  SiloClientTests.swift
//  LumeTests
//
//  Where Lume looks for a Silo server's Jellyfin-compatible service, given
//  the public URL the admin configured and the address the user entered.
//

import Foundation
@testable import Lume
import Testing

struct SiloClientTests {
    private let entered = URL(string: "http://192.168.178.114:8095")!

    @Test func `a loopback public URL moves to the entered host, keeping its port`() {
        let candidates = SiloClient.compatCandidates(publicURL: "http://127.0.0.1:8097", entered: entered)
        #expect(candidates.map(\.absoluteString) == ["http://192.168.178.114:8097"])
    }

    @Test func `localhost and IPv6 loopback count as loopback`() {
        #expect(SiloClient.compatCandidates(publicURL: "http://localhost:8097", entered: entered).map(\.absoluteString)
            == ["http://192.168.178.114:8097"])
        #expect(SiloClient.compatCandidates(publicURL: "http://[::1]:8097", entered: entered).map(\.absoluteString)
            == ["http://192.168.178.114:8097"])
    }

    @Test func `a routable public URL is tried first, then the entered host`() {
        let candidates = SiloClient.compatCandidates(publicURL: "https://jf.example.com/jellyfin/", entered: entered)
        #expect(candidates.map(\.absoluteString) == [
            "https://jf.example.com/jellyfin",
            "https://192.168.178.114/jellyfin"
        ])
    }

    @Test func `a public URL on the entered host is tried once`() {
        let candidates = SiloClient.compatCandidates(publicURL: "http://192.168.178.114:8097", entered: entered)
        #expect(candidates.map(\.absoluteString) == ["http://192.168.178.114:8097"])
    }

    @Test func `no public URL falls back to the default port on the entered host`() {
        let candidates = SiloClient.compatCandidates(publicURL: "  ", entered: entered)
        #expect(candidates.map(\.absoluteString) == ["http://192.168.178.114:8096"])
    }

    @Test func `silo sync walks login then movies then series`() {
        #expect(SyncStep.steps(for: .silo) == [.authenticating, .movies, .series])
    }

    @Test func `silo is a media server without live channels or downloads`() {
        let type = PlaylistSourceType.silo
        #expect(type.isMediaServer)
        #expect(!type.canCarryLiveChannels)
        #expect(!type.supportsRecording)
        #expect(MediaServerFlavor(sourceType: type) == .silo)
        #expect(MediaServerFlavor.silo.idInfix == "silo")
    }
}
