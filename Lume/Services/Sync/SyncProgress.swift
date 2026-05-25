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

// MARK: - Sync Steps

enum SyncStep: Int, CaseIterable, Identifiable, Sendable {
    case authenticating
    case movieCategories
    case seriesCategories
    case liveCategories
    case movies
    case series
    case liveStreams

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .authenticating: return "Authenticating"
        case .movieCategories: return "Movie categories"
        case .seriesCategories: return "Series categories"
        case .liveCategories: return "Live TV categories"
        case .movies: return "Movies"
        case .series: return "Series"
        case .liveStreams: return "Live TV channels"
        }
    }

    var systemImage: String {
        switch self {
        case .authenticating: return "person.badge.key"
        case .movieCategories: return "folder"
        case .seriesCategories: return "folder"
        case .liveCategories: return "folder"
        case .movies: return "film.stack"
        case .series: return "tv"
        case .liveStreams: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Step state

enum SyncStepState: Sendable {
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
        let total = Double(SyncStep.allCases.count)
        let done = Double(completedSteps.count)
        let active = currentStep != nil ? stepFraction : 0
        return min(1, (done + active) / total)
    }
}
