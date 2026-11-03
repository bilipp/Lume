//
//  HueSourceRouter.swift
//  Lume
//
//  Picks which of several players' frame sources drives Hue sync — in
//  Multi-View, the tile with the audio. Players register their source under a
//  key while they are on screen; the selected key's source is handed on, and a
//  key with nothing registered hands on none, which holds the lamps' colours.
//  Registrations and selections are events, never per frame.
//

import Foundation

final class HueSourceRouter<Key: Hashable> {
    private let debounce: Duration
    private let route: ((any HueFrameSource)?) -> Void
    private var sources: [Key: any HueFrameSource] = [:]
    private var selected: Key?
    private weak var routed: (any HueFrameSource)?
    private var pendingSelection: Task<Void, Never>?

    /// - Parameter route: receives the selected key's source, or nil, each
    ///   time that changes.
    init(debounce: Duration, route: @escaping ((any HueFrameSource)?) -> Void) {
        self.debounce = debounce
        self.route = route
    }

    func register(_ source: any HueFrameSource, for key: Key) {
        sources[key] = source
        if key == selected { update() }
    }

    /// Ignored when another source already replaced `source` under `key`: a
    /// player going away may report after its successor registered.
    func unregister(_ source: any HueFrameSource, for key: Key) {
        guard sources[key] === source else { return }
        sources[key] = nil
        if key == selected { update() }
    }

    /// Selects `key` once it has stayed selected for the debounce interval, so
    /// flicking through tiles doesn't swap the lamps' source at every step.
    @discardableResult
    func select(_ key: Key?) -> Task<Void, Never> {
        pendingSelection?.cancel()
        let delay = debounce
        let task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self else { return }
            selectNow(key)
        }
        pendingSelection = task
        return task
    }

    func selectNow(_ key: Key?) {
        pendingSelection?.cancel()
        pendingSelection = nil
        selected = key
        update()
    }

    /// Forgets every source and selection without routing anything.
    func reset() {
        pendingSelection?.cancel()
        pendingSelection = nil
        sources.removeAll()
        selected = nil
        routed = nil
    }

    private func update() {
        let source = selected.flatMap { sources[$0] }
        guard source !== routed else { return }
        routed = source
        route(source)
    }
}
