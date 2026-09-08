//
//  ContentSyncManager+M3UStream.swift
//  Lume
//
//  The m3u import's producer/consumer seam: a parse running off the sync actor
//  classifies each batch and hands it to a bounded channel, and a
//  consumer on the actor performs every SwiftData write, still strictly
//  serialized and still in file order.
//
//  Its own file because ContentSyncManager+M3U.swift sits against SwiftLint's
//  file-length limit.
//

import Foundation
import OSLog
import SwiftData

// MARK: - Channel

/// One parsed *and classified* batch on its way from the parse to the writer.
nonisolated struct M3UParsedBatch {
    var classified: M3UClassifiedBatch
    /// Bytes of the file consumed at this batch's last line — the import's only
    /// honest progress denominator (the entry count isn't known until the end).
    var bytesConsumed: Int
}

/// A bounded, back-pressuring hand-off between the m3u parse and the writer.
///
/// Deliberately not an `AsyncStream`: every bounded `AsyncStream.Continuation`
/// buffering policy *drops* elements rather than suspending the producer —
/// `.bufferingOldest(n)` discards the newest batch, `.bufferingNewest(n)` the
/// oldest — and a dropped batch would silently lose catalog rows *and* poison
/// the seen-sets the post-import sweeps prune against (C2/C3: a row the file
/// names but the import never wrote is a row the sweep then deletes, which the
/// next iCloud reconcile pushes to every device). `send` here returns only once
/// the consumer has taken a slot.
///
/// Bounding is the other half. The parser massively outruns the writer, so an
/// unbounded buffer would hold the whole 520 MB file — giving back exactly the
/// 502 MB → 10 MB parser footprint cap the previous commit bought, on a device
/// with no swap.
actor M3UBatchChannel {
    private let capacity: Int
    private var buffer: [M3UParsedBatch] = []
    private var producerFinished = false
    private var isClosed = false
    /// One producer and one consumer, so a single parked continuation each.
    private var waitingProducer: CheckedContinuation<Void, Never>?
    private var waitingConsumer: CheckedContinuation<M3UParsedBatch?, Never>?

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Hands a batch over, suspending while the buffer is full. Returns `false`
    /// once the consumer has stopped taking batches, which is the producer's
    /// signal to abandon the parse.
    func send(_ batch: M3UParsedBatch) async -> Bool {
        guard !isClosed else { return false }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: batch)
            return true
        }
        buffer.append(batch)
        guard buffer.count >= capacity else { return true }
        await withCheckedContinuation { continuation in
            waitingProducer = continuation
        }
        return !isClosed
    }

    /// The parse has delivered its last batch (or failed). Anything already
    /// buffered is still drained by the consumer.
    func finish() {
        producerFinished = true
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: nil)
        }
    }

    /// The next batch, or `nil` once the producer has finished and the buffer is
    /// drained. Never parks while the producer could be parked: `send` only
    /// waits with a non-empty buffer, and this only waits with an empty one.
    func next() async -> M3UParsedBatch? {
        if !buffer.isEmpty {
            let batch = buffer.removeFirst()
            if let producer = waitingProducer {
                waitingProducer = nil
                producer.resume()
            }
            return batch
        }
        guard !producerFinished, !isClosed else { return nil }
        return await withCheckedContinuation { continuation in
            waitingConsumer = continuation
        }
    }

    /// The consumer has stopped early (cancelled, or a batch failed). Releases a
    /// producer parked on back-pressure so the parse can unwind instead of
    /// waiting for a reader that will never come back.
    func close() {
        isClosed = true
        buffer.removeAll()
        if let producer = waitingProducer {
            waitingProducer = nil
            producer.resume()
        }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: nil)
        }
    }
}

// MARK: - Producer

/// The off-actor half of the import: parse, classify, and feed the channel.
///
/// Explicitly `nonisolated` (type and body) because
/// `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` would otherwise pin it to the main
/// actor, and it must never touch `M3UImportState` — that type is a plain class
/// with no synchronization, owned entirely by the consumer (C6).
nonisolated enum M3UBatchProducer {
    /// Unwinds the parse when the consumer has stopped taking batches. Never
    /// surfaces to a caller.
    private struct ConsumerGone: Error {}

    /// Streams `fileURL` into `channel`, returning the playlist's `#EXTM3U`
    /// header once the file is exhausted. Each batch is classified here, before
    /// the hand-off, so the writer only ever sees finished work.
    ///
    /// `@concurrent` is load-bearing, not decoration: `SWIFT_APPROACHABLE_CONCURRENCY`
    /// turns on `nonisolated(nonsending)`, under which a plain `nonisolated async`
    /// function runs on its *caller's* executor — here the sync actor, which would
    /// serialize the parse behind the writes and leave this seam no faster than the
    /// synchronous loop it replaces.
    @concurrent
    static func run(fileURL: URL, batchSize: Int, into channel: M3UBatchChannel) async throws -> M3UHeader? {
        var header: M3UHeader?
        // `.m3uParse` measures the gap between batches — the parse work itself.
        // It stops at each hand-off and restarts after it, so time spent parked
        // on back-pressure is charged to neither parse nor upsert. Every
        // interval is balanced on every exit; an interval left open never
        // resolves in a trace and the benchmarks read these by name.
        var parseInterval: PerfInterval? = Perf.begin(.m3uParse)
        func endParseInterval() {
            guard let interval = parseInterval else { return }
            Perf.end(interval)
            parseInterval = nil
        }

        do {
            try await M3UParser.parseStreaming(fileURL: fileURL, batchSize: batchSize) { parsed in
                header = parsed
            } onBatch: { entries, bytesConsumed in
                endParseInterval()
                // `.m3uClassify` still begins and ends exactly once per batch;
                // it is just charged to the producer now rather than the writer.
                let classified = Perf.measure(.m3uClassify) {
                    M3UBatchClassifier.classify(entries)
                }
                // Each side drains its own pool and never the other's: the
                // producer's are `parseStreaming`'s per-chunk pool (the hand-off
                // deliberately happens after it drains) and the classifier's own
                // pool, the consumer's wraps each batch import.
                let batch = M3UParsedBatch(classified: classified, bytesConsumed: bytesConsumed)
                guard await channel.send(batch) else { throw ConsumerGone() }
                parseInterval = Perf.begin(.m3uParse)
            }
        } catch {
            endParseInterval()
            await channel.finish()
            guard error is ConsumerGone else { throw error }
            return header
        }

        endParseInterval()
        await channel.finish()
        return header
    }
}

// MARK: - Import

extension ContentSyncManager {
    /// Entries per batch. A memory contract, not a throughput one — 500 / 2k /
    /// 10k / 50k all measured within noise, and raising it raises peak RSS on a
    /// device with no swap (C5).
    private static let m3uBatchSize = 2000

    /// Batches allowed in flight, ~8,000 entries at `m3uBatchSize`. Enough to
    /// keep the writer fed across a parse hiccup, small enough that the parser
    /// can never run away with the file.
    private static let m3uChannelCapacity = 4

    /// How many batches pass between progress publishes and between log lines.
    /// A provider file runs ~860 batches, and every publish hops onto
    /// SyncProgress's MainActor isolation; the final count is reported once the
    /// import returns, so throttling here only coarsens the intermediate steps.
    private static let progressBatchInterval = 5
    private static let logBatchInterval = 50

    /// Stream-parses the playlist file and upserts entries batch by batch.
    ///
    /// The parse and classification run as an `async let` child, off this actor;
    /// the writes stay here, one fresh autosave-off `ModelContext` per batch, in
    /// file order (C4 — `num` is the entry's file position, the classifier
    /// reassembles its chunks by index and the channel is FIFO). The two
    /// overlap, and — unlike the synchronous loop this replaces — the import now
    /// has real suspension points, so cancellation is cooperative rather than
    /// something that has to travel through `M3UImportState.firstError`.
    func importM3UFile(_ fileURL: URL, playlistId: UUID, progress: SyncProgress?) async throws -> M3UImportSummary {
        let state = M3UImportState()
        // Bytes, not entries: the parse learns the entry count only once it has
        // finished, so the file size is the only denominator a running import
        // can report a fraction against. 0 means "unknown" — the fraction then
        // stays 0, which SyncProgress renders as indeterminate.
        let totalBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        seedImportState(state, playlistId: playlistId)

        let channel = M3UBatchChannel(capacity: Self.m3uChannelCapacity)
        async let parsed = M3UBatchProducer.run(
            fileURL: fileURL, batchSize: Self.m3uBatchSize, into: channel
        )
        await consumeM3UBatches(
            from: channel, playlistId: playlistId, state: state, totalBytes: totalBytes, progress: progress
        )

        var header: M3UHeader?
        var producerError: Error?
        do {
            header = try await parsed
        } catch {
            // A parse failure the consumer never saw. Reported below, and
            // unwrapped: `performM3USync` surfaces a file error as itself,
            // where a batch failure is wrapped in `SyncError.databaseError`.
            producerError = error
        }

        if let error = state.firstError {
            // A cancellation is rethrown as-is rather than wrapped: `syncPlaylist`
            // reads that as an abort and parks the playlist idle, where a
            // `SyncError.databaseError` would wedge it in `.error`.
            throw error is CancellationError ? error : SyncError.databaseError(error)
        }
        if let producerError { throw producerError }

        // A cancel landing after the last batch still has to stop here: the
        // seen-sets only name the part of the file that was read, so sweeping on
        // them would delete every row the unread tail would have kept.
        try Task.checkCancellation()

        pruneStaleM3URows(playlistId: playlistId, state: state)

        return M3UImportSummary(
            liveCount: state.importedLive,
            movieCount: state.importedMovies,
            episodeCount: state.importedEpisodes,
            headerEPGURL: header?.epgURL
        )
    }

    /// Drains the channel, writing every batch on this actor. Never throws:
    /// both stop conditions are recorded on `state` so the caller can decide
    /// between rethrowing a cancellation and wrapping a store failure.
    private func consumeM3UBatches(
        from channel: M3UBatchChannel,
        playlistId: UUID,
        state: M3UImportState,
        totalBytes: Int,
        progress: SyncProgress?
    ) async {
        var batchIndex = 0
        var pacingPause: Duration = .zero
        while let batch = await channel.next() {
            if state.noteCancellationIfNeeded() { break }
            do {
                try autoreleasepool {
                    try self.importBatch(batch.classified, playlistId: playlistId, state: state)
                }
            } catch {
                state.firstError = error
                break
            }
            batchIndex += 1
            let imported = state.totalImported
            if batchIndex.isMultiple(of: Self.logBatchInterval) {
                Logger.database.info("m3u import: \(imported) items so far")
            }
            if batchIndex.isMultiple(of: Self.progressBatchInterval) {
                let fraction = totalBytes > 0 ? min(1, Double(batch.bytesConsumed) / Double(totalBytes)) : 0
                // Never awaited: the writer is the import's critical path, and
                // MainActor is already busy with the @Query invalidation this
                // same import causes. The intermediate publishes are advisory —
                // the final count is reported once the import returns.
                Task { await progress?.update(detail: "\(imported) items", fraction: fraction) }
            }
            pacingPause = await paceAfterM3UBatch(previousPause: pacingPause)
        }
        // Unblocks a producer parked on back-pressure after an early stop; a
        // no-op once the parse has already finished.
        await channel.close()
    }

    /// Stands down before the next batch when the device is already throttling
    /// or its owner has asked for conservation. Returns the pause it applied so
    /// the caller can log the valve's position only when it moves — a line per
    /// batch would be ~860 of them.
    ///
    /// Nominal and fair devices get exactly `.zero` here, so the import's
    /// wall clock in the normal case (and in every benchmark, since a simulator
    /// only ever reports `.nominal`) is untouched.
    private func paceAfterM3UBatch(previousPause: Duration) async -> Duration {
        let pause = ImportPacing.pauseBetweenBatches(
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        guard pause > .zero else {
            if previousPause > .zero {
                Logger.database.info("m3u import pacing: pressure cleared, resuming at full speed")
            }
            return .zero
        }
        if pause != previousPause {
            let milliseconds = Int(pause.milliseconds)
            Logger.database.info(
                "m3u import pacing: standing down \(milliseconds, privacy: .public)ms between batches"
            )
        }
        // A cancellation landing inside the pause is picked up at the top of the
        // consume loop, the one place the import records it.
        try? await Task.sleep(for: pause)
        return pause
    }
}
