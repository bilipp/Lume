//
//  WhatsNewSheet.swift
//  Lume
//
//  What an update brought, shown once after it: the release's highlights for
//  this platform, a way into the full history, and Continue. A sheet on iOS,
//  iPadOS, macOS and visionOS, a full-screen cover on tvOS.
//

import SwiftUI

struct WhatsNewSheet: View {
    let release: WhatsNewRelease

    @Environment(\.dismiss) private var dismiss
    /// Flips once on appear and drives the staggered entrance: the icon, the
    /// headline, each highlight in turn, then the buttons.
    @State private var isRevealed = false

    private var items: [WhatsNewItem] {
        release.highlights(on: .current)
    }

    var body: some View {
        NavigationStack {
            content
            #if !os(tvOS) && !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #elseif os(tvOS)
        .background(.regularMaterial)
        #else
        .presentationSizing(.form)
        #endif
        .accessibilityIdentifier("whatsNew.sheet")
        .onAppear { isRevealed = true }
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
                    .whatsNewReveal(stage: items.count + 2, isRevealed: isRevealed)
            }
            .frame(maxWidth: 1100)
            .padding(60)
        }
    #else
        private var content: some View {
            ScrollView {
                VStack(spacing: 32) {
                    header
                    VStack(alignment: .leading, spacing: 24) {
                        highlightRows
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 44)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actions
                    .whatsNewReveal(stage: items.count + 2, isRevealed: isRevealed)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    #endif

    private var highlightRows: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            WhatsNewItemRow(item: item)
                .whatsNewReveal(stage: index + 2, isRevealed: isRevealed)
        }
    }

    private var header: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: Self.iconSize * 0.46))
                .foregroundStyle(.tint)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: Self.iconSize * 0.24, style: .continuous))
                .whatsNewReveal(stage: 0, isRevealed: isRevealed, zooms: true)
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
            NavigationLink {
                WhatsNewHistoryView()
            } label: {
                Text("All Release Notes", tableName: "WhatsNew")
                #if os(tvOS)
                    .frame(maxWidth: .infinity)
                #endif
            }
            #if !os(tvOS)
            .buttonStyle(.borderless)
            #endif

            Button {
                dismiss()
            } label: {
                Text("Continue")
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
/// blur, each stage a beat after the one before. With Reduce Motion on it only
/// fades, all at once.
private struct WhatsNewReveal: ViewModifier {
    let stage: Int
    let isRevealed: Bool
    let zooms: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDisplaced: Bool {
        !isRevealed && !reduceMotion
    }

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .scaleEffect(zooms && isDisplaced ? 0.6 : 1)
            .blur(radius: isDisplaced ? 12 : 0)
            .offset(y: isDisplaced && !zooms ? 48 : 0)
            .opacity(isRevealed ? 1 : 0)
            .animation(animation, value: isRevealed)
    }

    private var animation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.3)
        }
        let delay = 0.5 + Double(stage) * 0.12
        return zooms ? .bouncy(duration: 0.7).delay(delay) : .smooth(duration: 0.7).delay(delay)
    }
}

private extension View {
    func whatsNewReveal(stage: Int, isRevealed: Bool, zooms: Bool = false) -> some View {
        modifier(WhatsNewReveal(stage: stage, isRevealed: isRevealed, zooms: zooms))
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
