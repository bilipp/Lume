//
//  EPGFocusStrip.swift
//  Lume
//
//  The tvOS guide's single real focus target plus its edge sentinels. The
//  engine only consults `shouldUpdateFocus` when a move has a candidate
//  target — with nothing focusable inside the guide, moves towards its
//  interior would be silently ignored. The sentinels hug the strip so every
//  interior direction always yields a proposal; the veto then reads the
//  move's *heading* (not which view the engine picked) and forwards it to the
//  guide's virtual navigation, covering remote presses *and* swipes even when
//  a strong neighbour like the tab bar is the engine's proposed target.
//
//  Two moves leave the guide. Up from the top row hands off to the tab bar
//  directly above: the up sentinel is dropped so the engine's only upward
//  candidate is that full-width neighbour, and the veto yields the move. Left
//  from the channel hub goes back to the category rail. A full-height view
//  projects its focus from screen centre, so the engine
//  finds no candidate on the top-aligned rail; and driving the SwiftUI rail's
//  focus state from here loses a fight with the UIKit strip (focus falls back
//  to the tab bar). So a `UIFocusGuide` at the leading edge points at the
//  rail's *container* view (the left-adjacent sibling, found by walking up):
//  the engine descends into it and focuses a category — pure UIKit, no
//  SwiftUI focus fight, and independent of where focus entered from. The
//  guide is live only while the strip holds focus: enabled on the unfocused
//  strip it would swallow every entry move from the rail instead.
//
//  Menu is deliberately *not* handled here. A responder-chain `pressesBegan`
//  loses to an enclosing NavigationStack's own Menu recognizer (focus hops to
//  the tab bar), and a competing recognizer with blanket precedence freezes
//  the engine's directional recognizers. The scroller handles Menu with
//  SwiftUI's `onExitCommand`, which takes the press before the stack does;
//  `railExitToken` is its hand-off back into UIKit for the hub → rail step.
//

#if os(tvOS)
    import SwiftUI
    import UIKit

    struct EPGFocusStrip: UIViewRepresentable {
        /// Reflects the strip's real (engine) focus.
        @Binding var isFocused: Bool
        /// Whether a left move should leave the guide (channel hub) rather
        /// than navigate virtually (programme cells).
        let exitsLeft: Bool
        /// Whether an up move should leave the guide (top row → tab bar)
        /// rather than navigate virtually to the row above.
        let exitsUp: Bool
        /// Handles a consumed directional move.
        let onMove: (MoveCommandDirection) -> Void
        let onSelect: () -> Void
        let onLongSelect: () -> Void
        /// Whether focus just walked out of the strip (Left, Up, or Menu to
        /// the rail); runs right before `isFocused` turns false.
        let onDeparture: (_ walkedOut: Bool) -> Void
        /// Bumped by the scroller to hand real focus to the rail (Menu from
        /// the hub). A token, not a call: the UIKit move must run outside the
        /// SwiftUI action that requested it.
        let railExitToken: Int
        /// What VoiceOver reads. The strip itself is the focused element, so a
        /// SwiftUI label on its host never reaches it.
        let accessibilityLabel: String
        /// The hub's long-press actions for VoiceOver, built only when it asks
        /// so nothing here observes the channel's favourite flag.
        let accessibilityActions: () -> [UIAccessibilityCustomAction]

        func makeUIView(context: Context) -> ContainerView {
            let view = ContainerView()
            view.lastRailExitToken = railExitToken
            apply(to: view, context: context)
            return view
        }

        func updateUIView(_ view: ContainerView, context: Context) {
            apply(to: view, context: context)
        }

        private func apply(to view: ContainerView, context _: Context) {
            view.strip.onFocusChange = { focused, walkedOut in
                Task { @MainActor in
                    if !focused { onDeparture(walkedOut) }
                    isFocused = focused
                }
            }
            view.strip.onMove = onMove
            view.strip.onSelect = onSelect
            view.strip.onLongSelect = onLongSelect
            view.setExitsLeft(exitsLeft)
            view.setExitsUp(exitsUp)
            view.strip.actionsProvider = accessibilityActions
            if view.strip.accessibilityLabel != accessibilityLabel {
                view.strip.accessibilityLabel = accessibilityLabel
                // Virtual moves never move real focus, so VoiceOver has to be
                // told the focused element now reads differently.
                if view.strip.isEngineFocused, UIAccessibility.isVoiceOverRunning {
                    UIAccessibility.post(notification: .layoutChanged, argument: view.strip)
                }
            }
            if view.lastRailExitToken != railExitToken {
                view.lastRailExitToken = railExitToken
                view.moveFocusToRail()
            }
        }

        /// The strip, its interior sentinels, and the leading-edge guide.
        final class ContainerView: UIView {
            let strip = StripView()
            private var sentinels: [MoveCommandDirection: SentinelView] = [:]
            /// The leading-edge focus guide, retargeted by focus state. While
            /// the strip is unfocused it points *at the strip*: a rightward
            /// move from the rail lands here (the engine finds no candidate on
            /// the strip itself under some hosting hierarchies, e.g. inside a
            /// NavigationStack) and is redirected in — deterministic entry.
            /// While the strip is focused on the hub it points at the rail's
            /// container, carrying the left exit out.
            private let edgeGuide = UIFocusGuide()
            private var exitsLeft = false
            /// Last applied rail-exit token (see `EPGFocusStrip.railExitToken`).
            var lastRailExitToken = 0
            /// Temporarily overrides the container's preferred focus for a
            /// programmatic hand-off to the rail.
            private var preferredOverride: [UIFocusEnvironment] = []

            override init(frame: CGRect) {
                super.init(frame: frame)
                for direction: MoveCommandDirection in [.up, .down, .left, .right] {
                    let sentinel = SentinelView()
                    sentinel.strip = strip
                    sentinels[direction] = sentinel
                    addSubview(sentinel)
                }
                strip.onEngineFocusChanged = { [weak self] in
                    self?.refreshEdgeGuide()
                }
                addSubview(strip)

                addLayoutGuide(edgeGuide)
                edgeGuide.isEnabled = false
                NSLayoutConstraint.activate([
                    edgeGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
                    edgeGuide.topAnchor.constraint(equalTo: topAnchor),
                    edgeGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
                    edgeGuide.widthAnchor.constraint(equalToConstant: 2)
                ])
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func setExitsLeft(_ exits: Bool) {
                exitsLeft = exits
                strip.exitsLeft = exits
                // On the hub the left sentinel yields to the edge guide so a
                // left move leaves; on a cell it stays as the interior veto.
                sentinels[.left]?.isFocusEnabled = !exits
                refreshEdgeGuide()
            }

            func setExitsUp(_ exits: Bool) {
                strip.exitsUp = exits
                // On the top row the up sentinel yields so an up move finds the
                // tab bar directly above and leaves; on deeper rows it stays as
                // the interior veto that drives row-to-row navigation. No edge
                // guide is needed as for the left exit — the tab bar is a
                // full-width neighbour the engine finds by projecting straight
                // up, where the top-aligned rail is missed by a sideways scan.
                sentinels[.up]?.isFocusEnabled = !exits
            }

            override var preferredFocusEnvironments: [UIFocusEnvironment] {
                preferredOverride.isEmpty ? super.preferredFocusEnvironments : preferredOverride
            }

            /// Hands real focus to the rail (Menu from the hub): a
            /// programmatic focus update requested from outside the engine's
            /// own callbacks, which the engine honours.
            func moveFocusToRail() {
                guard strip.isEngineFocused, let rail = railContainer() else { return }
                strip.walksOut = true
                preferredOverride = [rail]
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
                preferredOverride = []
            }

            private func refreshEdgeGuide() {
                // Exit only — and only while the strip actually holds focus.
                // An enabled guide on the *unfocused* strip sits at the
                // guide's leading edge and swallows every entry move from the
                // rail, redirecting it straight back (a visual no-op): that
                // was the "right does nothing" bug. Entry needs no guide; the
                // engine finds the strip through the guide's focus section.
                if strip.isEngineFocused, exitsLeft, let rail = railContainer() {
                    edgeGuide.preferredFocusEnvironments = [rail]
                    edgeGuide.isEnabled = true
                } else {
                    edgeGuide.isEnabled = false
                }
            }

            /// The rail's container: the *leftmost* sibling lying wholly to the
            /// strip's left, across every ancestor level. Taking the smallest
            /// `minX` skips the guide's own channel column (a nearer left
            /// sibling) and reaches the rail outside the guide. Walked from the
            /// tree so the UIKit strip needs no direct reference to the SwiftUI
            /// rail; pointing a focus guide at the container (not a leaf) lets
            /// the engine descend and focus the rail's remembered category.
            /// Empty leaves are skipped: before tvOS 26 the rail's material
            /// fallback adds childless graphics and hit-testing views with the
            /// rail's exact frame ahead of it, and a guide aimed at one of
            /// those goes nowhere, so Left and Menu never reached the rail.
            private func railContainer() -> UIFocusEnvironment? {
                guard let window else { return nil }
                let stripFrame = strip.convert(strip.bounds, to: window)
                var best: UIView?
                var bestMinX = CGFloat.greatestFiniteMagnitude
                var node: UIView = self
                while let parent = node.superview {
                    for sibling in parent.subviews where sibling !== node {
                        let frame = sibling.convert(sibling.bounds, to: window)
                        if frame.maxX <= stripFrame.minX + 1, frame.width > 100, frame.height > 100,
                           frame.minX < bestMinX, !sibling.subviews.isEmpty || sibling.canBecomeFocused
                        {
                            best = sibling
                            bestMinX = frame.minX
                        }
                    }
                    node = parent
                }
                return best
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                let inset: CGFloat = 2
                strip.frame = bounds.insetBy(dx: inset, dy: inset)
                sentinels[.up]?.frame = CGRect(x: inset, y: 0, width: bounds.width - 2 * inset, height: inset)
                sentinels[.down]?.frame = CGRect(x: inset, y: bounds.height - inset, width: bounds.width - 2 * inset, height: inset)
                sentinels[.left]?.frame = CGRect(x: 0, y: inset, width: inset, height: bounds.height - 2 * inset)
                sentinels[.right]?.frame = CGRect(x: bounds.width - inset, y: inset, width: inset, height: bounds.height - 2 * inset)
            }
        }

        /// A proposal target the strip vetoes moves onto; never actually
        /// focused. Only a candidate while the strip itself holds focus, so
        /// it guarantees every interior direction has something to move
        /// toward (triggering the veto) without stealing entry focus.
        final class SentinelView: UIView {
            var isFocusEnabled = true
            weak var strip: StripView?

            override init(frame: CGRect) {
                super.init(frame: frame)
                backgroundColor = UIColor.black.withAlphaComponent(0.01)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override var canBecomeFocused: Bool {
                isFocusEnabled && strip?.isEngineFocused == true
            }
        }

        final class StripView: UIView {
            var onFocusChange: ((_ focused: Bool, _ walkedOut: Bool) -> Void)?
            var onMove: ((MoveCommandDirection) -> Void)?
            var onSelect: (() -> Void)?
            var onLongSelect: (() -> Void)?
            /// Notifies the container of engine focus changes (guide retarget).
            var onEngineFocusChanged: (() -> Void)?
            /// Whether a left move leaves the guide (hub) or navigates (cell).
            var exitsLeft = false
            /// Whether an up move leaves the guide (top row) or navigates.
            var exitsUp = false

            private(set) var isEngineFocused = false
            /// Whether the last action walks focus out. Every press resets it,
            /// so a stale walk-out the engine had no target for can't misreport
            /// a later presentation.
            var walksOut = false
            var actionsProvider: (() -> [UIAccessibilityCustomAction])?
            private var longPressFired = false
            private var moveConsumed = false

            override init(frame: CGRect) {
                super.init(frame: frame)
                // Near-invisible but non-zero: fully transparent views are
                // dropped from the engine's directional candidacy.
                backgroundColor = UIColor.black.withAlphaComponent(0.01)
                isAccessibilityElement = true

                let select = UITapGestureRecognizer(target: self, action: #selector(handleSelect))
                select.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
                addGestureRecognizer(select)

                let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongSelect(_:)))
                long.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
                long.minimumPressDuration = 0.4
                addGestureRecognizer(long)
            }

            @available(*, unavailable)
            required init?(coder _: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override var canBecomeFocused: Bool {
                true
            }

            override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
                get { actionsProvider?() }
                set {}
            }

            override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
                super.didUpdateFocus(in: context, with: coordinator)
                if context.nextFocusedView === self {
                    isEngineFocused = true
                    walksOut = false
                    onEngineFocusChanged?()
                    onFocusChange?(true, false)
                } else if context.previouslyFocusedView === self {
                    isEngineFocused = false
                    onEngineFocusChanged?()
                    onFocusChange?(false, walksOut)
                }
            }

            override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
                guard isEngineFocused, context.previouslyFocusedView === self else { return true }
                // After a veto the engine synchronously retries with further
                // candidates; without this the same press would fire a second
                // action and let the retry carry real focus out of the guide.
                if moveConsumed { return false }
                // Decide from the *heading*, not from which view the engine
                // proposed: near a strong external neighbour (the tab bar
                // above, the rail beside) the engine may target it rather than
                // our edge sentinel, but the move is still ours to interpret.
                guard let direction = Self.direction(from: context.focusHeading) else { return true }
                // Left from the hub leaves the guide: allow the move so the
                // engine carries focus to the exit guide (→ the rail).
                if direction == .left, exitsLeft {
                    walksOut = true
                    return true
                }
                // Up from the top row leaves the guide: allow the move so the
                // engine carries focus to the tab bar above.
                if direction == .up, exitsUp {
                    walksOut = true
                    return true
                }
                // Every other direction stays inside: veto and navigate
                // virtually, even when the engine targeted the tab bar.
                walksOut = false
                moveConsumed = true
                Task { @MainActor in
                    self.moveConsumed = false
                    self.onMove?(direction)
                }
                return false
            }

            private static func direction(from heading: UIFocusHeading) -> MoveCommandDirection? {
                switch heading {
                case .up: .up
                case .down: .down
                case .left: .left
                case .right: .right
                default: nil
                }
            }

            @objc private func handleSelect() {
                guard !longPressFired else {
                    longPressFired = false
                    return
                }
                walksOut = false
                onSelect?()
            }

            @objc private func handleLongSelect(_ recognizer: UILongPressGestureRecognizer) {
                guard recognizer.state == .began else { return }
                longPressFired = true
                walksOut = false
                onLongSelect?()
            }
        }
    }
#endif
