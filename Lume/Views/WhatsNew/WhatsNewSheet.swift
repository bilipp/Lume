//
//  WhatsNewSheet.swift
//  Lume
//
//  What an update brought, shown once after it: the release's highlights for
//  this platform, a way into the full history, and Continue. A sheet on iOS,
//  iPadOS, macOS and visionOS, a full-screen cover on tvOS.
//
//  The release history opens the same page for any earlier release, with that
//  release's smaller notes under the highlights.
//

import SwiftUI

struct WhatsNewSheet: View {
    let release: WhatsNewRelease
    /// Opened from the release history rather than raised after an update:
    /// lists the notes too, and has no link back to the history it came from.
    var isReplay = false

    @Environment(\.dismiss) private var dismiss
    /// Flips once the sheet has settled and drives the staggered entrance:
    /// the icon, the headline, each highlight in turn, then the buttons.
    ///
    /// UI tests start revealed: a button that is still transparent takes no
    /// tap, so a test that taps as soon as the button exists would race the
    /// entrance.
    @State private var isRevealed = LumeApp.isAutomatedRun
    @State private var showsHistory = false

    #if os(iOS)
        /// The card is as tall as what it shows, like the system's welcome
        /// sheets: the scrolled content plus the buttons. Until both are
        /// measured, and while the history is open, it takes the full height.
        @State private var contentHeight: CGFloat?
        @State private var barHeight: CGFloat?

        private var detents: Set<PresentationDetent> {
            guard !showsHistory, let contentHeight, let barHeight else { return [.large] }
            return [.height(contentHeight + barHeight)]
        }
    #endif

    private var items: [WhatsNewItem] {
        release.highlights(on: .current)
    }

    private var notes: [LocalizedStringResource] {
        isReplay ? release.notes : []
    }

    /// The entrance stage of the buttons: after the icon, the headline, every
    /// highlight and the notes.
    private var actionsStage: Int {
        items.count + (notes.isEmpty ? 2 : 3)
    }

    var body: some View {
        NavigationStack {
            content
            #if !os(tvOS) && !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .navigationDestination(isPresented: $showsHistory) {
                WhatsNewHistoryView()
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #elseif os(tvOS)
        .background(.regularMaterial)
        #elseif os(iOS)
        .presentationSizing(.form)
        .presentationDetents(detents)
        #else
        .presentationSizing(.form)
        #endif
        .accessibilityIdentifier("whatsNew.sheet")
        .task {
            // The sheet slides up empty, as in the system's own welcome
            // sheets, and the content follows once it has settled. Flipping
            // on appear would also start while the sheet is still laying out.
            try? await Task.sleep(for: .seconds(0.4))
            isRevealed = true
        }
    }

    #if os(tvOS)
        /// Nothing scrolls here: the rows take no focus, so the two buttons are
        /// the only stops and a release keeps to five highlights.
        private var content: some View {
            VStack(spacing: 48) {
                header
                VStack(alignment: .leading, spacing: 32) {
                    highlightRows
                }
                actions
                    .whatsNewReveal(stage: actionsStage, isRevealed: isRevealed, rise: Self.actionsRise)
            }
            .frame(maxWidth: 1100)
            .padding(60)
        }
    #else
        /// The buttons sit on the sheet's own background. On 26 a scroll edge
        /// effect separates them from content scrolled underneath, and only
        /// then; before 26 they take the sheet's background colour.
        @ViewBuilder
        private var content: some View {
            let scroll = ScrollView {
                VStack(spacing: 32) {
                    header
                    VStack(alignment: .leading, spacing: 24) {
                        highlightRows
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 44)
                .padding(.bottom, 16)
                #if os(iOS)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                #endif
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            if #available(iOS 26, macOS 26, visionOS 26, *) {
                scroll.safeAreaBar(edge: .bottom, spacing: 0) { actionBar }
            } else {
                scroll.safeAreaInset(edge: .bottom, spacing: 0) {
                    actionBar.background(.background)
                }
            }
        }

        private var actionBar: some View {
            actions
                .whatsNewReveal(stage: actionsStage, isRevealed: isRevealed, rise: Self.actionsRise)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            #if os(iOS)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            #endif
        }
    #endif

    /// The buttons rise less than the content above them: they sit at the
    /// bottom edge and shouldn't come up from beyond it.
    private static let actionsRise: CGFloat = 24

    @ViewBuilder
    private var highlightRows: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            WhatsNewItemRow(item: item)
                .whatsNewReveal(stage: index + 2, isRevealed: isRevealed)
        }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .whatsNewReveal(stage: items.count + 2, isRevealed: isRevealed)
        }
    }

    private var header: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: Self.iconSize * 0.46))
                .foregroundStyle(.tint)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: Self.iconSize * 0.24, style: .continuous))
                .whatsNewReveal(stage: 0, isRevealed: isRevealed)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("What’s New in Lume", tableName: "WhatsNew")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Version \(release.version.displayString)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .whatsNewReveal(stage: 1, isRevealed: isRevealed)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }

    private static var iconSize: CGFloat {
        #if os(tvOS)
            120
        #else
            76
        #endif
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if !isReplay {
                Button {
                    showsHistory = true
                } label: {
                    Text("All Release Notes", tableName: "WhatsNew")
                    #if os(tvOS)
                        .frame(maxWidth: .infinity)
                    #endif
                }
                #if !os(tvOS)
                .buttonStyle(.borderless)
                #endif
            }

            Button {
                dismiss()
            } label: {
                Text(isReplay ? LocalizedStringKey("Done") : LocalizedStringKey("Continue"))
                    .frame(maxWidth: .infinity)
                #if !os(tvOS)
                    .padding(.vertical, 6)
                #endif
            }
            .whatsNewProminentButtonStyle()
            .accessibilityIdentifier("whatsNew.continue")
            #if os(tvOS)
                .focused($focusedAction, equals: .continue)
            #else
                .keyboardShortcut(.defaultAction)
            #endif
        }
        #if os(tvOS)
        .frame(maxWidth: 700)
        .defaultFocus($focusedAction, .continue)
        #endif
    }

    #if os(tvOS)
        private enum Action { case `continue` }
        @FocusState private var focusedAction: Action?
    #endif
}

/// One step of the sheet's entrance: the content rises into place out of a
/// heavy blur, settling without overshoot, each stage a beat after the one
/// before. With Reduce Motion on it only fades, all at once.
///
/// Starts only once the sheet has settled: any layout change in the same
/// update (the sheet still sizing itself) would take this curve too.
private struct WhatsNewReveal: ViewModifier {
    let stage: Int
    let isRevealed: Bool
    let rise: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDisplaced: Bool {
        !isRevealed && !reduceMotion
    }

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .blur(radius: isDisplaced ? 16 : 0)
            .offset(y: isDisplaced ? rise : 0)
            .opacity(isRevealed ? 1 : 0)
            .animation(animation, value: isRevealed)
    }

    private var animation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.3)
        }
        return .smooth(duration: 0.65).delay(Double(stage) * 0.17)
    }
}

private extension View {
    func whatsNewReveal(stage: Int, isRevealed: Bool, rise: CGFloat = 80) -> some View {
        modifier(WhatsNewReveal(stage: stage, isRevealed: isRevealed, rise: rise))
    }

    /// The filled call to action: Liquid Glass on iOS and macOS 26, the
    /// prominent bordered style before it and on visionOS, which has no glass
    /// button style. tvOS keeps the system button, whose focus treatment is
    /// the emphasis there (the accent resolves to white on tvOS).
    @ViewBuilder
    func whatsNewProminentButtonStyle() -> some View {
        #if os(tvOS)
            self
        #elseif os(visionOS)
            buttonStyle(.borderedProminent).controlSize(.large)
        #else
            if #available(iOS 26, macOS 26, *) {
                buttonStyle(.glassProminent).controlSize(.large)
            } else {
                buttonStyle(.borderedProminent).controlSize(.large)
            }
        #endif
    }
}
