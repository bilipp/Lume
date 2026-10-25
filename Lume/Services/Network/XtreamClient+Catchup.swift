//
//  XtreamClient+Catchup.swift
//  Lume
//
//  Catch-up (timeshift) URL construction for Xtream Codes panels. Split from
//  XtreamClient.swift, which sits against SwiftLint's file-length limit; the
//  static builder is also what the m3u `xc` catch-up dialect calls through
//  `M3UCatchupURL`.
//

import Foundation

extension XtreamClient {
    /// `Y-m-d:H-i` is the start format Xtream Codes panels expect in a timeshift
    /// path. The value is wall-clock time in the timezone advertised by the
    /// account. Fall back to the device timezone for older panels that omit it,
    /// preserving Lume's historical behaviour for those providers.
    private nonisolated static func timeshiftStartString(for start: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        return formatter.string(from: start)
    }

    /// Everything a timeshift URL needs that is not the programme window.
    ///
    /// Exists so the m3u `xc` catch-up dialect can reach the builder below: those
    /// channels hit an Xtream panel, but their credentials and provider stream id
    /// live in the channel URL path rather than on the models (an m3u `Playlist`
    /// has no credentials and `LiveStream.streamId` is an FNV hash).
    nonisolated struct TimeshiftTarget {
        let serverURL: String
        let username: String
        let password: String
        let streamId: Int
        let container: String
        let timeZone: TimeZone
    }

    /// The timeshift path itself, without a `Playlist`/`LiveStream` pair.
    /// `M3UCatchupURL` calls straight through here so both sources build one
    /// path shape.
    ///
    /// The programme window arrives as its two dates and the minutes convention
    /// lives here alone: panels answer 400 on a zero-minute request, so a window
    /// shorter than a minute rounds up to one rather than becoming unplayable.
    nonisolated static func buildCatchupURL(
        _ target: TimeshiftTarget,
        start: Date,
        end: Date
    ) -> URL? {
        let durationMinutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded(.up)))
        let startString = timeshiftStartString(for: start, timeZone: target.timeZone)
        return URL(string: "\(target.serverURL)/timeshift/\(target.username)/\(target.password)/\(durationMinutes)/\(startString)/\(target.streamId).\(target.container)")
    }

    /// Builds a catch-up / timeshift URL for a past programme on a live stream.
    ///
    /// Uses the Xtream Codes timeshift path
    /// `…/timeshift/user/pass/{durationMinutes}/{Y-m-d:H-i}/{streamId}.{ext}`,
    /// where the duration is the programme length in minutes and the start is the
    /// programme's air time. Only meaningful for Xtream streams: m3u channels
    /// carry no credentials, and the m3u `xc` dialect reaches the static
    /// builder above through `M3UCatchupURL` instead.
    nonisolated func buildCatchupURL(
        for stream: LiveStream,
        playlist: Playlist,
        start: Date,
        end: Date,
        format: StreamFormat? = nil
    ) -> URL? {
        // Xtream-compatible panels commonly expose catch-up as an MPEG-TS
        // resource even when normal live playback defaults to HLS. Respect an
        // explicit playlist/argument choice, but prefer TS when it is unknown.
        let ext = Self.resolvedFormat(format, playlist: playlist, fallback: .tsStream).rawValue
        return Self.buildCatchupURL(
            TimeshiftTarget(
                serverURL: playlist.serverURL,
                username: playlist.username,
                password: playlist.password,
                streamId: stream.streamId,
                container: ext,
                timeZone: playlist.serverTimezone.flatMap(TimeZone.init(identifier:)) ?? .current
            ),
            start: start,
            end: end
        )
    }
}
