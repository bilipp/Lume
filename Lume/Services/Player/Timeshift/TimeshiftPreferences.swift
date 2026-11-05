import Foundation

nonisolated enum TimeshiftPreferences {
    static let durationKey = "player.timeshift.minutes"
    static let programmeTimelineKey = "player.timeshift.programmeTimeline"
    static let measuredBitrateKey = "player.timeshift.measuredBitsPerSecond"
    static let defaultMinutes = 15
    static let minuteOptions = Array(1 ... 4) + Array(stride(from: 5, through: 60, by: 5))
    static let fallbackBitsPerSecond: Double = 8_000_000

    static func normalizedMinutes(_ value: Int) -> Int {
        let bounded = min(max(value, 1), 60)
        return bounded < 5 ? bounded : ((bounded + 2) / 5) * 5
    }

    static func minutes(in defaults: UserDefaults = .standard) -> Int {
        normalizedMinutes(defaults.object(forKey: durationKey) == nil ? defaultMinutes : defaults.integer(forKey: durationKey))
    }

    static func estimatedBytes(minutes: Int, bitsPerSecond: Double) -> Int64 {
        let bitrate = bitsPerSecond.isFinite && bitsPerSecond > 0 ? bitsPerSecond : fallbackBitsPerSecond
        let bytes = Double(normalizedMinutes(minutes)) * 60 * min(bitrate, 1_000_000_000) / 8
        return Int64(bytes.rounded(.up))
    }

    static func displayDuration(engine: Double, programme: Double?, limitToProgramme: Bool) -> Double {
        let measured = engine.isFinite ? max(0, engine) : 0
        guard limitToProgramme, let programme, programme.isFinite, programme > 0 else { return measured }
        return programme
    }
}
