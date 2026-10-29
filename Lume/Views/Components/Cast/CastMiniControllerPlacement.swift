//
//  CastMiniControllerPlacement.swift
//  Lume
//
//  Places the Chromecast mini-controller above the tab bar. iOS 26.1 has
//  `tabViewBottomAccessory(isEnabled:)`, which follows the tab bar as it
//  minimizes; earlier systems get a glass bar inset at the bottom of each
//  tab's content, which keeps it above the tab bar there. iOS 26.0's accessory
//  can only be toggled by adding or removing the modifier, which would rebuild
//  the whole `TabView`, so 26.0 takes the inset too.
//
//  iOS only; everywhere else both modifiers return the view unchanged.
//

import SwiftUI

extension View {
    /// Shows the Chromecast mini-controller over this `TabView` while a cast
    /// plays with no player open. A tap hands the stream Lume loaded to
    /// `openPlayer`, else presents the status-only casting remote.
    @ViewBuilder
    func castMiniController(openPlayer: @escaping (PlayableMedia) -> Void) -> some View {
        #if os(iOS)
            modifier(CastMiniControllerHost(openPlayer: openPlayer))
        #else
            self
        #endif
    }

    /// The mini-controller's place in one tab's content, before iOS 26.1.
    @ViewBuilder
    func castMiniControllerInset() -> some View {
        #if os(iOS)
            if #available(iOS 26.1, *) {
                self
            } else {
                modifier(CastMiniControllerInset())
            }
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct CastMiniControllerHost: ViewModifier {
        @State private var model: CastMiniControllerModel

        init(openPlayer: @escaping (PlayableMedia) -> Void) {
            _model = State(initialValue: CastMiniControllerModel(openPlayer: openPlayer))
        }

        func body(content: Content) -> some View {
            @Bindable var model = model
            content
                .bottomAccessoryIfAvailable(model: model)
                .environment(model)
                .onAppear { model.start() }
                .onDisappear { model.stop() }
                .onChange(of: model.isVisible, initial: true) { model.refresh() }
                .onChange(of: model.castService.isChromecastActive) { _, active in
                    if !active {
                        model.showsRemote = false
                    }
                }
                .fullScreenCover(isPresented: $model.showsRemote) {
                    CastPlaybackView(
                        receiver: model,
                        onStop: {
                            model.stopCasting()
                            model.showsRemote = false
                        },
                        onClose: { model.showsRemote = false }
                    )
                }
        }
    }

    private extension View {
        @ViewBuilder
        func bottomAccessoryIfAvailable(model: CastMiniControllerModel) -> some View {
            if #available(iOS 26.1, *) {
                tabViewBottomAccessory(isEnabled: model.isVisible) {
                    CastMiniControllerAccessory(model: model)
                }
            } else {
                self
            }
        }
    }

    @available(iOS 26.1, *)
    private struct CastMiniControllerAccessory: View {
        let model: CastMiniControllerModel
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        var body: some View {
            CastMiniControllerBar(model: model, isInline: placement == .inline)
                .padding(.leading, placement == .inline ? 8 : 10)
                .padding(.trailing, 6)
        }
    }

    /// The pre-26.1 bar: glass on iOS 26.0, a material capsule before.
    private struct CastMiniControllerInset: ViewModifier {
        @Environment(CastMiniControllerModel.self) private var model: CastMiniControllerModel?

        func body(content: Content) -> some View {
            let isVisible = model?.isVisible ?? false
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if let model, isVisible {
                    CastMiniControllerBar(model: model)
                        .padding(.leading, 10)
                        .padding(.trailing, 6)
                        .padding(.vertical, 6)
                        .glassEffectCompat(.regularInteractive, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: isVisible)
        }
    }
#endif
