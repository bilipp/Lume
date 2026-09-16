//
//  ContentSyncManager+WebDAVWalk.swift
//  Lume
//
//  The producer half of the WebDAV import: a recursive `Depth: 1` PROPFIND walk
//  that synthesizes `M3UEntry` values, and a feeder that streams them into the
//  same bounded channel the m3u parse feeds, so the writer, the batching, the
//  pacing and the sweeps are one code path.
//
//  The walk finishes before the feeder starts, which the m3u path deliberately
//  does not do. It is what the listing fingerprint costs: a share has no single
//  artifact to hash, so the fingerprint exists only once every directory has
//  been listed, and a skip decided after the import had already run would skip
//  nothing. The listing is held as synthesized entries plus one signature
//  string per file — the signatures are released when the walk returns — and
//  the entries are handed to the writer in bounded batches exactly as before,
//  so only the listing itself, never the classified rows, is resident at once.
//
//  Its own file because ContentSyncManager+WebDAV.swift carries the
//  orchestration and both sit under SwiftLint's file-length limit.
//

import Foundation
import OSLog

// MARK: - Result

nonisolated struct WebDAVWalkResult {
    /// One synthesized m3u entry per playable file, in walk order.
    var entries: [M3UEntry] = []
    var directoriesVisited = 0
    /// Whether the walk emptied its queue without throwing. The prune sweeps
    /// read this and nothing else: a walk that 401'd, timed out or was
    /// cancelled partway names only the part of the share it reached, and
    /// sweeping on that deletes rows together with the favorites and watch
    /// progress keyed to them — which the next iCloud reconcile then pushes to
    /// every device.
    var isComplete = false
    /// SHA-256 over the sorted per-file signatures. Empty until the walk
    /// completes, and never recorded before the import that follows it commits.
    var fingerprint = ""
}

// MARK: - Producer

/// Explicitly `nonisolated` (type and body) because
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` would otherwise pin it to the main
/// actor. It touches no `M3UImportState`: that type is owned entirely by the
/// consumer on the sync actor.
nonisolated enum WebDAVWalkProducer {
    /// Entries per batch, and batches in flight. Smaller than the m3u import's
    /// 2,000 to keep peak resident classified rows down; measured at 500 / 2k /
    /// 10k / 50k, batch size is within noise on throughput either way.
    static let batchSize = 500
    static let channelCapacity = 4

    /// Walks `root` and everything beneath it, listing one directory per
    /// `Depth: 1` PROPFIND.
    ///
    /// `@concurrent` is load-bearing: `SWIFT_APPROACHABLE_CONCURRENCY` turns on
    /// `nonisolated(nonsending)`, under which a plain `nonisolated async`
    /// function runs on its caller's executor — here the sync actor, which
    /// would serialize every PROPFIND and every XML parse behind the writes.
    @concurrent
    static func walk(
        root: URL,
        credentials: WebDAVCredentials?,
        client: WebDAVClient,
        progress: SyncProgress?
    ) async throws -> WebDAVWalkResult {
        let base = WebDAVClient.normalizedCollectionURL(root)
        let rootKey = visitKey(base)
        let rootGroup = lastSegment(of: base)
        var queue: [(url: URL, folders: [String])] = [(base, [])]
        // An index cursor rather than `removeFirst()`, which is O(n) per
        // directory on a share with thousands of folders.
        var cursor = 0
        var visited: Set<String> = [rootKey]
        var result = WebDAVWalkResult()
        // Local, so it is released the moment the fingerprint has been taken —
        // nothing but the hash outlives the walk.
        var signatures: [String] = []

        while cursor < queue.count {
            try Task.checkCancellation()
            let directory = queue[cursor]
            cursor += 1

            let resources = try await client.list(directory.url, credentials: credentials)
            result.directoriesVisited += 1

            for resource in resources {
                if resource.isCollection {
                    let key = visitKey(resource.url)
                    guard isDescendant(key, of: rootKey) else { continue }
                    // A symlinked directory pointing back up the share would
                    // otherwise walk forever. This is termination, not a depth
                    // or request cap.
                    guard visited.insert(key).inserted else { continue }
                    queue.append((resource.url, directory.folders + [resource.name]))
                    continue
                }
                guard let entry = entry(for: resource, folders: directory.folders, group: rootGroup) else { continue }
                result.entries.append(entry)
                signatures.append(WebDAVListingFingerprint.signature(for: resource))
            }

            await publish(files: result.entries.count, directories: result.directoriesVisited, to: progress)
        }

        result.fingerprint = WebDAVListingFingerprint.make(from: signatures)
        result.isComplete = true

        let files = result.entries.count
        let directories = result.directoriesVisited
        Logger.database.info(
            "WebDAV walk finished: \(files, privacy: .public) media file(s) in \(directories, privacy: .public) folder(s)"
        )
        return result
    }

    /// Classifies the walked listing in batches and hands them to the writer,
    /// stopping the moment the consumer has gone.
    ///
    /// `bytesConsumed` carries the entry count here rather than a byte offset:
    /// paired with `totalBytes: entries.count` at the call site it gives the
    /// import step a real fraction, which the m3u path — whose entry count is
    /// unknown until its parse ends — cannot have.
    @concurrent
    static func feed(_ entries: [M3UEntry], into channel: M3UBatchChannel) async {
        var index = 0
        while index < entries.count {
            let upper = min(index + batchSize, entries.count)
            let classified = M3UBatchClassifier.classify(Array(entries[index ..< upper]))
            index = upper
            guard await channel.send(M3UParsedBatch(classified: classified, bytesConsumed: upper)) else { break }
        }
        await channel.finish()
    }

    // MARK: - Entry synthesis

    /// One media file as the m3u pipeline expects it, or `nil` for anything the
    /// catalog cannot play.
    private static func entry(for resource: WebDAVResource, folders: [String], group: String?) -> M3UEntry? {
        guard let ext = M3UClassifier.pathExtension(of: resource.url.absoluteString),
              MediaFilenameParser.mediaExtensions.contains(ext)
        else { return nil }

        let parsed = MediaFilenameParser.parse(filename: resource.name, folders: folders)
        return M3UEntry(
            name: parsed.name,
            url: resource.url.absoluteString,
            tvgId: nil,
            logo: nil,
            group: group,
            // A file share carries no live channels, and the explicit VOD
            // marker is the one signal `M3UClassifier` checks before its URL
            // heuristics — which would otherwise read a folder named "Live" or
            // a `.ts` container as a live endpoint and file the row under a tab
            // a WebDAV playlist does not show.
            type: "video"
        )
    }

    // MARK: - Progress

    private static func publish(files: Int, directories: Int, to progress: SyncProgress?) async {
        // Fraction stays 0 — SyncProgress reads that as indeterminate. A tree's
        // size is unknowable until the walk has finished, exactly as an m3u
        // file's entry count is; inventing a denominator would make the bar
        // march backwards every time a new folder turns up.
        await progress?.update(detail: String(localized: "\(files) files in \(directories) folders"))
    }

    // MARK: - Identity

    /// Cycle-detection key: scheme, host and percent-decoded path, without
    /// query or trailing slash. Case-sensitive — a WebDAV path is.
    private static func visitKey(_ url: URL) -> String {
        let absolute = url.absoluteString
        let withoutQuery = absolute.split(separator: "?", maxSplits: 1).first.map(String.init) ?? absolute
        let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }

    /// Whether a listed href is actually inside the collection the user named.
    /// Apache aliases and Nextcloud shares can return hrefs that resolve above
    /// the share root; walking those would leave the user's folder entirely.
    private static func isDescendant(_ key: String, of rootKey: String) -> Bool {
        key == rootKey || key.hasPrefix(rootKey + "/")
    }

    /// The collection's own folder name. Every file in the share inherits it as
    /// its browse category — the file-share equivalent of m3u's group-title. A
    /// share has no curated categories, so subdividing by subfolder would file
    /// each episode-named folder as its own category and scatter one series
    /// across dozens of them.
    private static func lastSegment(of url: URL) -> String? {
        guard let segment = url.path(percentEncoded: false).split(separator: "/").last else { return nil }
        return String(segment)
    }
}
