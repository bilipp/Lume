//
//  OnboardingView.swift
//  Lume
//
//  The "How Lume Works" guide: one paged card per `OnboardingStep`, shown once on
//  a fresh device before the add-playlist form and re-openable from Settings.
//
//  Leaving the guide is the caller's job. `onFinish` fires for both Skip and the
//  final button, and this view never reads `@Environment(\.dismiss)`: on macOS
//  that closes the app's only window when the guide is root content, and
//  `@Environment(\.isPresented)` is `true` there too (see `LoginView.isModal`).
//

import SwiftUI

// tvOS never renders this view — `ContentView` and `MainTabView` layer
// `TVOnboardingOverlay` directly, because a tvOS `fullScreenCover` self-dismisses
// on the Menu press the guide claims for itself.
#if !os(tvOS)

    struct OnboardingView: View {
        /// Whether the guide is presented modally (the first-launch cover/sheet)
        /// rather than pushed from Settings for re-reading. The modal copy offers
        /// Skip and ends on the "Add Playlist" hand-off; the pushed copy ends on a
        /// plain Done and has the navigation bar's back button to leave by.
        ///
        /// Passed explicitly rather than read from `@Environment(\.isPresented)`,
        /// which reads `true` even for non-presented root content on macOS.
        var isModal = false

        /// Called when the user leaves the guide — Skip, or the final button. The
        /// caller owns both the dismissal and the `onboarding.seenVersion.v1` write.
        var onFinish: () -> Void

        /// The page the guide rests on. `@State` on purpose: backgrounding mid-guide
        /// resumes on the same step, and no per-step progress is persisted.
        ///
        /// The index, not the scrolled-to id, is the source of truth. A paging
        /// scroll writes `nil` back through `.scrollPosition(id:)` while it is in
        /// flight, so deriving the page from that binding let a second Continue tap
        /// land on a `nil` read, fall back to page one and walk the tour backwards.
        @State private var stepIndex = 0

        private var steps: [OnboardingStep] {
            OnboardingStep.steps
        }

        private var currentIndex: Int {
            min(max(stepIndex, 0), max(steps.count - 1, 0))
        }

        private var isLastStep: Bool {
            currentIndex >= steps.count - 1
        }

        var body: some View {
            standardBody
        }

        // MARK: - iOS / iPadOS / macOS / visionOS

        /// The modal copy carries its own `NavigationStack` and window sizing; the
        /// Settings re-read is pushed into the stack Settings already owns, and
        /// nesting a second one there would draw a second title bar.
        @ViewBuilder
        private var standardBody: some View {
            if isModal {
                NavigationStack {
                    guideContent
                }
                .onboardingModalFrame()
            } else {
                guideContent
            }
        }

        private var guideContent: some View {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    stepPages
                    pageIndicator
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            // The modal copy names itself in the header; the pushed copy inherits
            // Settings' navigation bar. Stating it in both drew the title twice.
            .navigationTitle(isModal ? Text(verbatim: "") : Text(
                "How Lume Works",
                comment: "Title of the first-launch guide and of the Settings row that re-opens it"
            ))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }

        private var header: some View {
            VStack(spacing: 10) {
                if isModal {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text(
                        "How Lume Works",
                        comment: "Title of the first-launch guide and of the Settings row that re-opens it"
                    )
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                }
                Text(
                    "A quick tour of the app. It takes less than a minute.",
                    comment: "Subtitle under the first-launch guide's title"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }

        /// Drives the paging scroll from `stepIndex` and mirrors a user swipe
        /// back into it, dropping the `nil` a programmatic scroll writes while
        /// it is still in flight.
        private var scrollPosition: Binding<OnboardingStep.ID?> {
            Binding(
                get: { steps.indices.contains(currentIndex) ? steps[currentIndex].id : nil },
                set: { id in
                    guard let id, let index = steps.firstIndex(where: { $0.id == id }) else { return }
                    stepIndex = index
                }
            )
        }

        /// The steps as full-width pages. `ScrollView(.horizontal)` +
        /// `.scrollTargetBehavior(.paging)` rather than `PageTabViewStyle`, which
        /// does not exist on macOS (see `HomeHeroCarousel`).
        private var stepPages: some View {
            GeometryReader { proxy in
                let width = proxy.size.width
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(steps) { step in
                            stepCard(step)
                                .padding(.horizontal, 4)
                                .frame(width: width)
                                .id(step.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: scrollPosition)
                .scrollIndicators(.hidden)
            }
            .frame(height: 320)
        }

        private func stepCard(_ step: OnboardingStep) -> some View {
            VStack(spacing: 14) {
                Image(systemName: step.systemImage)
                    .font(.system(size: 46))
                    .foregroundStyle(.tint)
                    .frame(height: 58)
                Text(step.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(step.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // The page height is fixed so the buttons never shift; long
                    // translations (de, ja) shrink instead of truncating.
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .glassEffectCompat(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }

        /// The tour's position. Deliberately not `HeroPageIndicator`, which the
        /// task named: that component draws white dots on `.ultraThinMaterial`
        /// for legibility over hero artwork, and on a plain sheet it reads as a
        /// grey blob. Its `progress` fill is also meaningless here — the guide
        /// has no auto-advance.
        @ViewBuilder
        private var pageIndicator: some View {
            if steps.count > 1 {
                HStack(spacing: 8) {
                    ForEach(steps.indices, id: \.self) { index in
                        let isActive = index == currentIndex
                        Capsule()
                            .fill(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                            .frame(width: isActive ? 24 : 7, height: 7)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: currentIndex)
                .accessibilityHidden(true)
            }
        }

        private var actions: some View {
            VStack(spacing: 14) {
                Button(action: advance) {
                    Text(primaryTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.continue")

                if isModal {
                    Button(action: onFinish) {
                        Text(
                            "Skip",
                            comment: "Button that closes the first-launch guide without reading it"
                        )
                    }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.skip")
                }
            }
        }

        /// The last page hands off to the add-playlist form the launch chain shows
        /// next; re-read from Settings there is nothing to hand off to.
        private var primaryTitle: LocalizedStringResource {
            guard isLastStep else {
                return LocalizedStringResource(
                    "Continue",
                    comment: "Button that advances the first-launch guide to the next page"
                )
            }
            return isModal ? "Add Playlist" : "Done"
        }

        private func advance() {
            guard !isLastStep else {
                onFinish()
                return
            }
            withAnimation { stepIndex = currentIndex + 1 }
        }
    }

    private extension View {
        /// The macOS sheet has no intrinsic size around a `ScrollView`, so the
        /// modal copy states its own. In a separate modifier because SwiftFormat
        /// reindents an `#if` placed adjacent in a modifier chain.
        func onboardingModalFrame() -> some View {
            #if os(macOS)
                frame(minWidth: 520, idealWidth: 600, minHeight: 520, idealHeight: 660)
            #else
                self
            #endif
        }
    }

#endif
