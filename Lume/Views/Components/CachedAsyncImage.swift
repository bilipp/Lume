//
//  CachedAsyncImage.swift
//  Lume
//
//  A drop-in replacement for SwiftUI's `AsyncImage` that fixes the reliability
//  problems that make posters and backdrops fail to load:
//
//  • Memory + disk caching (see `ImagePipeline`), so images survive cell reuse
//    and app launches instead of re-downloading and flashing placeholders.
//  • Automatic retry on transient network failures, and a short freeze-out for
//    URLs that just failed so a dead poster isn't re-requested on every pass.
//  • Optional downsampling via `maxPixelSize` (longest edge in points; converted
//    to pixels using the display scale) to cut memory and decode time for cards.
//    Pass `nil` for full-resolution artwork such as tvOS 4K heroes.
//  • Fades in artwork that had to be fetched, while keeping cache hits instant.
//    Pass an explicit `transaction` to override, or `Transaction()` to disable.
//
//  The closure API mirrors `AsyncImage` — it hands back an `AsyncImagePhase`
//  (`.empty` / `.success` / `.failure`) — so migrating a call site is usually
//  just renaming `AsyncImage` to `CachedAsyncImage`.
//

import SwiftUI

struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    /// Longest edge to decode to, in points. `nil` keeps full resolution.
    private let maxPixelSize: CGFloat?
    private let transaction: Transaction
    private let content: (AsyncImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: AsyncImagePhase = .empty

    /// Fades artwork in once it arrives from the network so posters don't hard-cut
    /// from placeholder to image. Cache hits are unaffected — `load()` resolves
    /// those synchronously outside the transaction, so they still appear instantly.
    static var defaultTransaction: Transaction {
        Transaction(animation: .easeIn(duration: 0.2))
    }

    init(
        url: URL?,
        maxPixelSize: CGFloat? = nil,
        transaction: Transaction? = nil,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.transaction = transaction ?? Self.defaultTransaction
        self.content = content
    }

    var body: some View {
        // Bypass @State entirely when there is no URL: regardless of any stale
        // phase the SwiftUI state system might have preserved, callers always
        // receive .failure so they show a static placeholder immediately without
        // any spinner. The .task still fires so that a later URL change is picked
        // up, but load() exits immediately for nil URL.
        content(url == nil ? .failure(URLError(.badURL)) : phase)
            .task(id: taskID) { await load() }
    }

    /// Restart the load whenever the URL or target size changes (e.g. cell reuse).
    private var taskID: String {
        guard let url else { return "nil" }
        return ImagePipeline.memoryKey(url, maxPixelSize: pixelSize)
    }

    /// Target size in pixels, or `nil` for full resolution.
    private var pixelSize: CGFloat? {
        guard let maxPixelSize else { return nil }
        return maxPixelSize * displayScale
    }

    private func load() async {
        guard let url else {
            phase = .failure(URLError(.badURL))
            return
        }

        // Synchronous cache hit: render immediately, no placeholder flash.
        if let cached = ImagePipeline.cachedImage(for: url, maxPixelSize: pixelSize) {
            phase = .success(Image(platformImage: cached))
            return
        }

        if case .success = phase { phase = .empty }

        do {
            let image = try await ImagePipeline.shared.image(for: url, maxPixelSize: pixelSize)
            withTransaction(transaction) {
                phase = .success(Image(platformImage: image))
            }
        } catch {
            // The cell scrolled away mid-load: the shared fetch is now cancelled
            // with us (see `ImagePipeline`) so the posters still on screen aren't
            // stuck behind it. Leave the phase alone — this view is going away, and
            // a stored .failure would show the broken-artwork placeholder for a
            // beat if it comes back. `URLSession` reports a cancelled request as
            // `URLError.cancelled` rather than `CancellationError`, hence the helper.
            guard !ImagePipeline.isCancellation(error) else { return }
            withTransaction(transaction) {
                phase = .failure(error)
            }
        }
    }
}
