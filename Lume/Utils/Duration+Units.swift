//
//  Duration+Units.swift
//  Lume
//
//  `Duration` reports its magnitude only as a (seconds, attoseconds) pair, so
//  every caller that wants to log or compare one converts by hand. One
//  conversion, used by all of them.
//

import Foundation

nonisolated extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    var milliseconds: Double {
        seconds * 1000
    }
}
