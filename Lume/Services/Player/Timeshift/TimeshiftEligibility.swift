import Foundation

nonisolated enum TimeshiftEligibility {
    /// Archive playback is VOD even when its content reference is a live
    /// channel. Eligibility must follow playback mode, not archive availability.
    static func allows(isLive: Bool, url: URL, enabled: Bool) -> Bool {
        enabled && isLive && url.pathExtension.lowercased() == "m3u8"
            && ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
