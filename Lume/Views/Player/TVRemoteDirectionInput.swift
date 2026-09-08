//
//  TVRemoteDirectionInput.swift
//  Lume
//
//  The player's directional input on tvOS, and the one place that can tell a
//  click on the remote's direction buttons from a swipe across its touch
//  surface.
//
//  tvOS reports both through `onMoveCommand`, which is why every host in here
//  used to treat them alike. A click, though, also emits a `UIPress` of an
//  arrow type; a swipe emits none. So an observer watches for those presses and
//  `RemoteDirectionGate` pairs each one with the move it belongs to — in either
//  arrival order, since the focus engine's recognizers and ours run off the same
//  press event and UIKit doesn't promise which goes first.
//
//  The observer is a gesture recognizer that fails the moment it has read the
//  press, so it recognizes nothing and leaves the focus engine's own
//  recognizers alone: a recognizer here with any real precedence freezes them
//  (the same trap documented in `EPGFocusStrip`). It is attached to the window
//  because the focused view is SwiftUI's — a representable sits beside it, not
//  above it, and the window is the one ancestor both share. Being inert, it is
//  attached once and left there rather than tracked in and out of the player.
//
//  With swipes enabled — the shipped default — none of this runs: the handler
//  fires straight from the move command, exactly as before.
//

#if os(tvOS)

    import SwiftUI
    import UIKit

    extension View {
        /// Handles the player's directional input, honouring
        /// `PlayerSettings.tvRemoteSwipesKey`: every move when swipes are on,
        /// only clicks on the remote's direction buttons when they're off.
        ///
        /// A drop-in for `onMoveCommand` on any view that reads the remote's
        /// directions as *actions* — surfing channels, scrubbing, raising the
        /// controls. Not for views where a direction moves focus: those are the
        /// focus engine's to route, and it owns swipes there.
        func tvRemoteMoveCommand(perform: @escaping (MoveCommandDirection) -> Void) -> some View {
            onMoveCommand { direction in
                guard !PlayerSettings.tvRemoteSwipesEnabled else {
                    perform(direction)
                    return
                }
                TVRemoteDirectionInput.shared.handleMove(direction) { perform(direction) }
            }
            .background(TVRemoteDirectionProbe())
        }
    }

    /// Pairs the player's move commands with the remote's button presses, so a
    /// viewer who turned swipes off only ever acts on a click.
    ///
    /// A singleton because the press observer is one recognizer on one window
    /// and has no view to report to: the handler that recorded the move waiting
    /// to be paired is held here with it.
    @MainActor
    final class TVRemoteDirectionInput {
        static let shared = TVRemoteDirectionInput()

        private var gate = RemoteDirectionGate()
        /// The move waiting for the press that would confirm it, with the
        /// handler to run if it comes. Only ever one: a remote produces one
        /// direction at a time, and anything older has left the gate's window.
        private var pendingMove: (direction: MoveCommandDirection, perform: () -> Void)?
        private var isObserving = false

        private init() {}

        /// Runs `perform` if this move can be attributed to a button press.
        /// When the press half hasn't arrived yet the move is parked and
        /// `handlePress` runs it instead — a swipe parks a move that nothing
        /// ever claims.
        func handleMove(_ direction: MoveCommandDirection, perform: @escaping () -> Void) {
            guard let gated = RemoteDirectionGate.Direction(direction) else {
                // A direction the gate doesn't model can't be classified, so
                // let it through rather than swallow it.
                perform()
                return
            }
            pendingMove = nil
            if gate.noteMove(gated) {
                perform()
            } else {
                pendingMove = (direction, perform)
            }
        }

        /// Reports a click on one of the remote's direction buttons, running the
        /// move it confirms when that move arrived first.
        func handlePress(_ direction: MoveCommandDirection) {
            guard let gated = RemoteDirectionGate.Direction(direction) else { return }
            let parked = pendingMove
            pendingMove = nil
            guard gate.notePress(gated), let parked, parked.direction == direction else { return }
            parked.perform()
        }

        /// Attaches the press observer to `window`, once. Never detached: the
        /// recognizer fails on every press it reads, so it costs the focus
        /// engine nothing to leave in place, and tracking it against a player
        /// that mounts overlays over itself would only invite gaps.
        fileprivate func observePresses(in window: UIWindow) {
            guard !isObserving else { return }
            isObserving = true
            let observer = ArrowPressObserver()
            observer.allowedPressTypes = [
                UIPress.PressType.upArrow, .downArrow, .leftArrow, .rightArrow
            ].map { NSNumber(value: $0.rawValue) }
            window.addGestureRecognizer(observer)
        }
    }

    /// Reads the remote's arrow presses and recognizes nothing. `state` goes to
    /// `.failed` as soon as the press has been read, which is what keeps it out
    /// of the focus engine's way.
    private final class ArrowPressObserver: UIGestureRecognizer {
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
            super.pressesBegan(presses, with: event)
            for press in presses {
                guard let direction = Self.direction(for: press.type) else { continue }
                TVRemoteDirectionInput.shared.handlePress(direction)
            }
            state = .failed
        }

        private static func direction(for type: UIPress.PressType) -> MoveCommandDirection? {
            switch type {
            case .upArrow: .up
            case .downArrow: .down
            case .leftArrow: .left
            case .rightArrow: .right
            default: nil
            }
        }
    }

    /// A zero-size view whose only job is to hand the input a window to observe
    /// from. Applied by `tvRemoteMoveCommand`, so any gated surface arms it.
    private struct TVRemoteDirectionProbe: UIViewRepresentable {
        func makeUIView(context _: Context) -> ProbeView {
            ProbeView()
        }

        func updateUIView(_: ProbeView, context _: Context) {}

        final class ProbeView: UIView {
            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard let window else { return }
                TVRemoteDirectionInput.shared.observePresses(in: window)
            }
        }
    }

    extension RemoteDirectionGate.Direction {
        /// The gate's direction for a tvOS move command, or `nil` for a case
        /// the gate doesn't model (a future direction).
        init?(_ direction: MoveCommandDirection) {
            switch direction {
            case .up: self = .up
            case .down: self = .down
            case .left: self = .left
            case .right: self = .right
            default: return nil
            }
        }
    }

#endif
