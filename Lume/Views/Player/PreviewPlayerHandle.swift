//
//  PreviewPlayerHandle.swift
//  Lume
//
//  The seam between the tvOS Guide's live preview and full screen: the preview
//  tile registers the engine it actually started on and that engine's
//  coordinator here, so full screen can adopt the running stream instead of
//  opening a second connection to the provider.
//

import KSPlayer
import SwiftUI

@MainActor @Observable
final class PreviewPlayerHandle {
    nonisolated enum Owner: Equatable {
        case preview
        case fullScreen
        case released
    }

    enum EngineCoordinator {
        // swiftlint:disable:next identifier_name
        case ks(KSVideoPlayer.Coordinator)
        // swiftlint:disable:next identifier_name
        case av(AVPlayerCoordinator)
        case vlc(VLCPlayerCoordinator)
        case lume(LumeEngineCoordinator)

        func isSame(as other: EngineCoordinator) -> Bool {
            switch (self, other) {
            case let (.ks(lhs), .ks(rhs)): lhs === rhs
            case let (.av(lhs), .av(rhs)): lhs === rhs
            case let (.vlc(lhs), .vlc(rhs)): lhs === rhs
            case let (.lume(lhs), .lume(rhs)): lhs === rhs
            default: false
            }
        }

        var engine: PlayerEngineKind {
            switch self {
            case .ks: .ksPlayer
            case .av: .avPlayer
            case .vlc: .vlcKit
            case .lume: .lumeEngine
            }
        }

        var ksCoordinator: KSVideoPlayer.Coordinator? {
            guard case let .ks(coordinator) = self else { return nil }
            return coordinator
        }

        var avCoordinator: AVPlayerCoordinator? {
            guard case let .av(coordinator) = self else { return nil }
            return coordinator
        }

        func setMuted(_ muted: Bool) {
            switch self {
            case let .ks(coordinator): coordinator.isMuted = muted
            case let .av(coordinator): coordinator.isMuted = muted
            case let .vlc(coordinator): coordinator.isMuted = muted
            case let .lume(coordinator): coordinator.isMuted = muted
            }
        }

        func stop() {
            switch self {
            case let .ks(coordinator): coordinator.resetPlayer()
            case let .av(coordinator): coordinator.tearDown()
            case let .vlc(coordinator): coordinator.tearDown()
            case let .lume(coordinator): coordinator.tearDown()
            }
        }
    }

    /// Only `.preview` lets the preview tile reset, reconnect or tear down its
    /// player; any other owner means the running session is no longer its own.
    var owner: Owner = .preview
    var media: PlayableMedia?
    /// The Stalker-resolved stand-in for `media` the engine actually opened, so
    /// full screen reuses its URL instead of spending another `create_link`.
    var resolvedMedia: PlayableMedia?
    var coordinator: EngineCoordinator?
    var hasStarted = false

    /// Ignored while full screen owns the session: a preview tile mounting
    /// behind the cover must not replace the coordinator full screen adopted.
    func register(
        media: PlayableMedia,
        resolved: PlayableMedia?,
        coordinator: EngineCoordinator
    ) {
        guard owner != .fullScreen else { return }
        owner = .preview
        self.media = media
        resolvedMedia = resolved
        self.coordinator = coordinator
        hasStarted = false
    }

    /// Clears the registration a tile made, once that tile has torn its player
    /// down, unless another tile has registered since.
    func unregister(_ coordinator: EngineCoordinator) {
        guard owner == .preview,
              let current = self.coordinator,
              current.isSame(as: coordinator) else { return }
        self.coordinator = nil
        media = nil
        resolvedMedia = nil
        hasStarted = false
    }

    func markStarted() {
        guard owner == .preview else { return }
        hasStarted = true
    }

    /// From here on the preview tile leaves its player alone.
    func handOffToFullScreen() {
        guard owner == .preview else { return }
        owner = .fullScreen
    }

    func release() {
        owner = .released
        coordinator = nil
        hasStarted = false
    }

    /// Stops the preview's session now rather than when its tile next
    /// disappears, so the provider frees the connection before full screen
    /// opens its own. Releasing alone would make the tile skip its own
    /// teardown and leave the session running.
    func stopPreview() {
        if owner == .preview {
            coordinator?.stop()
        }
        release()
    }

    func canAdopt(_ selected: PlayableMedia, airPlayActive: Bool) -> Bool {
        guard owner == .preview, let coordinator else { return false }
        return Self.canAdopt(
            engine: coordinator.engine,
            hasStarted: hasStarted,
            previewMediaID: media?.id,
            selectedMediaID: selected.id,
            airPlayActive: airPlayActive
        )
    }

    /// Whether full screen may take over the preview's running player for
    /// `selectedMediaID`; otherwise the preview stops and full screen opens
    /// its own stream.
    nonisolated static func canAdopt(
        engine: PlayerEngineKind?,
        hasStarted: Bool,
        previewMediaID: String?,
        selectedMediaID: String,
        airPlayActive: Bool
    ) -> Bool {
        guard hasStarted, let engine,
              previewMediaID == selectedMediaID else { return false }
        return GuidePreviewPolicy.supportsHandoff(engine: engine, airPlayActive: airPlayActive)
    }
}

extension PreviewPlayerHandle? {
    /// False once the Guide preview's session belongs to full screen; always
    /// true for a tile with no handle.
    var ownsSession: Bool {
        map { $0.owner == .preview } ?? true
    }
}
