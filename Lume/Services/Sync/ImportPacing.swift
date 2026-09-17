//
//  ImportPacing.swift
//  Lume
//
//  How much the catalog import stands down between batches when the device is
//  already in trouble.
//

import Foundation

// MARK: - ImportPacing

/// The catalog import's thermal / Low Power Mode safety valve.
///
/// A **safety valve, not a throttle**: the heat a big import produces *is* its
/// wall clock, so the nominal and fair cases run flat out and finishing sooner
/// is what keeps the device cool. Only a device that is already throttling —
/// `.serious`/`.critical` — or one whose owner has explicitly asked for
/// conservation (Low Power Mode) buys a pause, and then only to stop the import
/// from bidding against the system's own mitigations.
///
/// The device state arrives as parameters rather than being read here: neither
/// `ProcessInfo.thermalState` nor `isLowPowerModeEnabled` is settable, and a
/// simulator never reports anything but `.nominal`, so the eight-case policy
/// below is only checkable with them supplied.
///
/// `isLowPowerModeEnabled` is documented as always `false` where the system has
/// no Low Power Mode, which is tvOS and visionOS: on those two the valve is
/// thermal-only and `lowPowerPause` is unreachable. Any future tuning aimed at
/// the Apple TV therefore has to move `seriousThermalPause` /
/// `criticalThermalPause`, never `lowPowerPause`.
nonisolated enum ImportPacing {
    /// Paid once per consumed batch, so ~860 times over a 1.7M-entry provider
    /// file: each millisecond here is roughly a second of import.
    static let lowPowerPause: Duration = .milliseconds(25)
    static let seriousThermalPause: Duration = .milliseconds(75)
    static let criticalThermalPause: Duration = .milliseconds(250)

    /// How long to stand down before consuming the next batch.
    ///
    /// The two pressures add rather than override: a `.serious` device in Low
    /// Power Mode is under both, and the escalation across the eight
    /// state × mode combinations has to be monotonic for the valve to be
    /// predictable. `.nominal` and `.fair` contribute nothing, which is why
    /// those two are equal at a given Low Power setting.
    static func pauseBetweenBatches(thermalState: ProcessInfo.ThermalState, isLowPower: Bool) -> Duration {
        let thermal: Duration = switch thermalState {
        case .nominal, .fair: .zero
        case .serious: seriousThermalPause
        case .critical: criticalThermalPause
        // A state Apple adds above `.critical` can only be worse than it.
        @unknown default: criticalThermalPause
        }
        return thermal + (isLowPower ? lowPowerPause : .zero)
    }
}
