//
//  SyncProgress.swift
//  Lume
//
//  Observable progress tracker for ContentSyncManager. The sync actor publishes
//  step transitions and batch counts into this object; the SyncProgressView
//  renders the current state.
//

import Foundation
import Observation
import SwiftUI

// MARK: - Sync Steps

enum SyncStep: Int, CaseIterable, Identifiable {
    case authenticating
    case movieCategories
    case seriesCategories
    case liveCategories
    case movies
    case series
    case liveStreams
    case epg
    // m3u-only steps
    case playlistDownload
    case playlistImport

    var id: Int {
        rawValue
    }

    /// The steps an Xtream sync walks through, in order.
    static let xtreamSteps: [SyncStep] = [
        .authenticating, .movieCategories, .seriesCategories, .liveCategories,
        .movies, .series, .liveStreams, .epg
    ]

    /// The steps an m3u sync walks through, in order.
    static let m3uSteps: [SyncStep] = [.playlistDownload, .playlistImport, .epg]

    static func steps(for sourceType: PlaylistSourceType) -> [SyncStep] {
        switch sourceType {
        case .xtream: xtreamSteps
        case .m3u: m3uSteps
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .authenticating: "Authenticating"
        case .movieCategories: "Movie categories"
        case .seriesCategories: "Series categories"
        case .liveCategories: "Live TV categories"
        case .movies: "Movies"
        case .series: "Series"
        case .liveStreams: "Live TV channels"
        case .epg: "TV guide"
        case .playlistDownload: "Downloading playlist"
        case .playlistImport: "Importing content"
        }
    }

    var systemImage: String {
        switch self {
        case .authenticating: "person.badge.key"
        case .movieCategories: "folder"
        case .seriesCategories: "folder"
        case .liveCategories: "folder"
        case .movies: "film.stack"
        case .series: "tv"
        case .liveStreams: "antenna.radiowaves.left.and.right"
        case .epg: "list.clipboard"
        case .playlistDownload: "arrow.down.circle"
        case .playlistImport: "square.and.arrow.down.on.square"
        }
    }
}

// MARK: - Step state

enum SyncStepState {
    case pending
    case active
    case completed
}

// MARK: - Progress tracker

/// MainActor-isolated by default per project config. The actor uses `await` to
/// publish updates, which hops onto MainActor — SwiftUI then reacts via
/// @Observable.
@Observable
final class SyncProgress {
    /// The ordered steps this sync walks through — Xtream and m3u playlists
    /// have different pipelines, so the progress view renders this list.
    let steps: [SyncStep]

    init(steps: [SyncStep] = SyncStep.xtreamSteps) {
        self.steps = steps
    }

    private(set) var currentStep: SyncStep?
    private(set) var completedSteps: Set<SyncStep> = []
    private(set) var stepDetail: String = ""
    /// 0...1 inside the active step. 0 means indeterminate / not applicable.
    private(set) var stepFraction: Double = 0

    func start(_ step: SyncStep) {
        currentStep = step
        stepDetail = ""
        stepFraction = 0
    }

    func complete(_ step: SyncStep) {
        completedSteps.insert(step)
        if currentStep == step {
            currentStep = nil
        }
    }

    func update(detail: String, fraction: Double = 0) {
        stepDetail = detail
        stepFraction = fraction
    }

    func state(for step: SyncStep) -> SyncStepState {
        if completedSteps.contains(step) { return .completed }
        if currentStep == step { return .active }
        return .pending
    }

    /// Overall fraction across all steps, useful for a top-level bar.
    var overallFraction: Double {
        let total = Double(steps.count)
        let done = Double(completedSteps.count)
        let active = currentStep != nil ? stepFraction : 0
        return min(1, (done + active) / total)
    }
}
