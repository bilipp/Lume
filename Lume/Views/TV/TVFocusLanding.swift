//
//  TVFocusLanding.swift
//  Lume
//
//  Landing focus deliberately on tvOS, instead of letting the focus engine
//  choose.
//
//  The engine picks geometrically: whatever sits nearest in the direction of
//  travel. That is right almost everywhere, and wrong in two situations this
//  file covers.
//
//  A surface that has just appeared over live content has to *take* focus, or
//  the content behind it stays live — the viewer keeps navigating a list they
//  can no longer read. Asking during the update that presents the surface never
//  works: the request names views the engine cannot see yet and is dropped. So
//  the incumbent is released, the surface is given a beat to mount, and only
//  then is the target asserted — off the focus engine's animated context.
//
//  Returning to a region the viewer has been in before has the opposite
//  problem: geometry lands them wherever they happen to be pointing, rather
//  than where they left off. `landTVFocus` asserts the remembered target in the
//  same way.
//
//  A `defaultFocus` (or `prefersDefaultFocus`) declaration states the same
//  target for the engine's own bookkeeping; it does not move focus on its own,
//  which is why the assertion here exists as well.
//

#if os(tvOS)

    import SwiftUI

    /// How long to let a newly-presented surface mount before asking for focus.
    let tvFocusSettleDelay: Duration = .milliseconds(150)

    /// Releases focus, waits for `target`'s view to mount, then asserts it.
    /// Call from a `Task`/`task` so it runs outside the presenting update.
    ///
    /// Pass `scrollingTo` whenever the target sits in a lazy stack: a row below
    /// the fold has not been realised, so a focus request naming it is dropped
    /// exactly as if the surface weren't on screen yet — the surface opens
    /// unfocused and whatever is behind it stays live.
    @MainActor
    func landTVFocus<Value: Hashable>(
        _ focus: FocusState<Value?>.Binding,
        on target: Value?,
        scrollingTo proxy: ScrollViewProxy? = nil,
        while stillPresented: () -> Bool = { true }
    ) async {
        guard let target else { return }
        focus.wrappedValue = nil
        // Without animation: this is not a scroll the viewer asked for, it is
        // putting the target where focus is about to land. Animating it would
        // be seen as the list moving on its own, and can still be travelling
        // when the focus highlight arrives.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy?.scrollTo(target, anchor: .center) }
        try? await Task.sleep(for: tvFocusSettleDelay)
        guard stillPresented() else { return }
        focus.wrappedValue = target
    }

#endif
