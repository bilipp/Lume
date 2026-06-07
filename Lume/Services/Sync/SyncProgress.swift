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

    var id: Int {
        rawValue
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
