//
//  OutroTrigger.swift
//  Lume
//
//  Decides when the end-of-episode Next Episode button arms, refining the
//  legacy fraction-of-duration heuristic with IntroDB's decoded outro segment.
//

import Foundation

/// Pure arm-time arithmetic for the in-player Next Episode button.
///
/// IntroDB is keyed only by series IMDb id + season + episode — there is no
/// runtime or hash check — while IPTV providers ship their own encodes with
/// different intros, ad breaks and trailing slates. A segment that doesn't
/// match the stream being played must therefore never win, so every window is
/// sanity-checked against the engine-reported duration before it is trusted.
nonisolated enum OutroTrigger {
    /// The legacy fraction-of-duration arm point, matched to
    /// `WatchProgressWriter`'s ≥90% "watched" line.
    static let fallbackFraction = 0.90

    /// How far before the end of the file the credits may end and still be
    /// plausible for this encode.
    private static let maxEndSlack: TimeInterval = 90

    /// How far an outro window may run *past* the reported duration and still
    /// be believed. A second or two is ordinary rounding between the container
    /// and the engine; more than that means the segment was timed against a
    /// longer cut than the one playing, so the whole window is suspect.
    private static let maxEndOvershoot: TimeInterval = 2

    /// The absolute time, in seconds, at which the Next Episode button should
    /// arm — or `nil` when `duration` is unknown or the stream is live, in
    /// which case callers keep whatever behaviour they had.
    ///
    /// A trusted outro arms at `max(outro.start, duration * fallbackFraction)`.
    /// The `max()` is deliberate and required, not a clamp that can be dropped:
    /// `WatchProgressWriter` marks an episode watched only at
    /// `progress / duration >= 0.9`, so a button armed below that line lets the
    /// viewer advance while the episode is still incomplete — it stays in
    /// Continue Watching forever and never scrobbles to Trakt. Arming *later*
    /// than 90% is the whole point (credits routinely start at 96%, leaving the
    /// legacy button sitting on top of minutes of plot); arming earlier is
    /// never allowed.
    static func armTime(outro: IntroSegments.Segment?, duration: TimeInterval) -> TimeInterval? {
        guard duration > 1 else { return nil }

        let fallback = duration * fallbackFraction

        guard let outro,
              outro.duration >= IntroSegments.minimumUsableDuration,
              outro.start > 0,
              outro.start < duration,
              isEndPlausible(outro.end, duration: duration)
        else {
            return fallback
        }

        return max(outro.start, fallback)
    }

    /// Whether credits ending at `end` are plausible for a file of `duration`.
    ///
    /// Slack is positive when the credits finish before the file does and
    /// negative when the window runs past the end of this encode. Both
    /// directions are bounded: a window ending far too early was timed against
    /// a different cut, and one ending past the file end could not have come
    /// from this stream at all.
    private static func isEndPlausible(_ end: TimeInterval, duration: TimeInterval) -> Bool {
        let slack = duration - end
        return slack <= maxEndSlack && slack >= -maxEndOvershoot
    }
}
