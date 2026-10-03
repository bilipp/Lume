//
//  KSHostedPlayerSurface.swift
//  Lume
//
//  Renders a KSPlayer session handed between the tvOS Guide preview and full
//  screen (see `PreviewPlayerHandle`) through a Lume-owned container instead of
//  `KSVideoPlayer`, whose `dismantleUIView` resets the player unconditionally —
//  which would kill a stream full screen has just adopted — and which would
//  return the running player view as its own root, still pinned by the
//  preview's Auto Layout.
//

#if os(tvOS)
    import KSPlayer
    import SwiftUI
    import UIKit

    struct KSHostedPlayerSurface: UIViewRepresentable {
        enum Mode {
            /// The Guide preview: leaves the player running when dismantled,
            /// and stops touching it once `handle` no longer belongs to the
            /// preview.
            case preview(PreviewPlayerHandle)
            /// Full screen's surface for an adopted session: follows URL changes
            /// (in-player channel surfing) the way `KSVideoPlayer` does, and
            /// resets the player when dismantled.
            case adopted

            var resetsOnDismantle: Bool {
                if case .adopted = self { true } else { false }
            }
        }

        final class Host {
            let player: KSVideoPlayer.Coordinator
            let resetsOnDismantle: Bool

            init(player: KSVideoPlayer.Coordinator, resetsOnDismantle: Bool) {
                self.player = player
                self.resetsOnDismantle = resetsOnDismantle
            }
        }

        let coordinator: KSVideoPlayer.Coordinator
        let url: URL
        let options: KSOptions
        let mode: Mode
        let onStateChanged: (KSPlayerLayer, KSPlayerState) -> Void
        var onPlay: ((TimeInterval, TimeInterval) -> Void)?

        func makeCoordinator() -> Host {
            Host(player: coordinator, resetsOnDismantle: mode.resetsOnDismantle)
        }

        func makeUIView(context _: Context) -> UIView {
            let container = UIView()
            container.backgroundColor = .black
            container.clipsToBounds = true
            attachCallbacks()
            // `makeView` hands back the running player view untouched when the
            // URL matches; it never re-prepares a live session.
            host(coordinator.makeView(url: url, options: options), in: container)
            return container
        }

        func updateUIView(_ container: UIView, context _: Context) {
            switch mode {
            case let .preview(handle):
                // Never re-adds the player view: after a handoff it lives in
                // full screen's hierarchy, and pulling it back would blank
                // full screen.
                guard handle.owner == .preview else { return }
                attachCallbacks()
            case .adopted:
                attachCallbacks()
                guard coordinator.playerLayer?.url != url else { return }
                host(coordinator.makeView(url: url, options: options), in: container)
            }
        }

        static func dismantleUIView(_: UIView, coordinator host: Host) {
            if host.resetsOnDismantle {
                host.player.resetPlayer()
            }
        }

        private func attachCallbacks() {
            coordinator.onStateChanged = onStateChanged
            if let onPlay {
                coordinator.onPlay = onPlay
            }
        }

        private func host(_ playerView: UIView, in container: UIView) {
            guard playerView.superview !== container else { return }
            container.subviews.forEach { $0.removeFromSuperview() }
            playerView.removeFromSuperview()
            playerView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(playerView)
            NSLayoutConstraint.activate([
                playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                playerView.topAnchor.constraint(equalTo: container.topAnchor),
                playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }
#endif
