//
//  ContentSyncManager+M3UCatchup.swift
//  Lume
//
//  The catch-up half of the m3u live importer.
//
//  m3u channels advertise an archive with a `catchup` dialect and an optional
//  `catchup-source` template rather than with the numeric `tv_archive` pair an
//  Xtream panel returns, so the importer has to translate one into the other:
//  the columns live TV, the guide and the player read are the Xtream ones, and
//  every consumer stays source-agnostic.
//
//  The translation happens exactly once, here, at import time — never per
//  rendered cell. See `catchupImport(for:)` for why the decision is *buildable*
//  rather than *declared*.
//

import Foundation
import SwiftData

extension ContentSyncManager {
    /// Writes the catch-up columns for one imported m3u channel.
    ///
    /// Assigned on every pass, the absent case included: the prune sweep removes
    /// vanished rows but never resets columns, so a dropped archive self-clears
    /// here.
    static func applyM3UCatchupFields(from entry: M3UEntry, to stream: LiveStream) {
        let catchup = catchupImport(for: entry)
        stream.tvArchive = catchup == nil ? 0 : 1
        stream.tvArchiveDuration = catchup?.days ?? 0
        stream.catchupType = catchup?.type
        stream.catchupSource = catchup?.source
    }

    /// The catch-up decision persisted for an m3u channel, `nil` when it declares
    /// none we can serve. `tvArchive` records *buildable*, not *declared* — the
    /// guide's row snapshot cannot run a URL builder per cell, so a scheme we cannot
    /// expand gets no affordance rather than a dead tap; days 0 is "depth unknown".
    private static func catchupImport(for entry: M3UEntry) -> (type: CatchupType, days: Int, source: String?)? {
        guard let type = CatchupType.parse(entry.catchupTypeRaw),
              let liveURL = URL(string: entry.url),
              M3UCatchupURL.canBuild(type: type, source: entry.catchupSource, liveURL: liveURL)
        else { return nil }
        return (type, entry.catchupDays ?? 0, entry.catchupSource)
    }
}
