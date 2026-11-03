//
//  MultiViewScreen+HueSync.swift
//  Lume
//
//  Multi-View's half of Philips Hue light sync. The screen opens its own
//  session and the lamps follow the tile with the audio: each tile registers
//  its engine's frame source under its slot, and a change of audible tile
//  only swaps the source. With no audible tile playing, the lamps hold their
//  colours. Leaving Multi-View or backgrounding ends the session and restores
//  the lamps. Guide previews never register: only this screen sets the slot.
//
//  tvOS only. Elsewhere the hooks return the view unchanged.
//

import SwiftUI

extension View {
    /// Runs Hue sync for Multi-View around this view, following `audioSlotID`.
    func multiViewHueSync(audioSlotID: MultiViewSlot.ID) -> some View {
        #if os(tvOS)
            modifier(MultiViewHueSync(audioSlotID: audioSlotID))
        #else
            self
        #endif
    }

    /// Marks the tile subtree belonging to `slotID`.
    func multiViewHueSlot(_ slotID: MultiViewSlot.ID) -> some View {
        #if os(tvOS)
            modifier(MultiViewHueSlot(slotID: slotID))
        #else
            self
        #endif
    }

    /// Registers a tile engine's frame source under its slot; Guide previews
    /// never register, wherever they are shown.
    func hueFrameSource(_ engine: some HueFrameSourceProviding, role: MultiViewTileRole) -> some View {
        #if os(tvOS)
            hueFrameSource(engine).transformEnvironment(\.hueFrameSourceSink) { sink in
                if case .guidePreview = role { sink = nil }
            }
        #else
            self
        #endif
    }
}

#if os(tvOS)
    extension EnvironmentValues {
        @Entry var multiViewHueRouter: HueSourceRouter<MultiViewSlot.ID>?
    }

    private struct MultiViewHueSync: ViewModifier {
        let audioSlotID: MultiViewSlot.ID

        @State private var router = HueSourceRouter<MultiViewSlot.ID>(debounce: .milliseconds(400)) {
            HueSyncController.shared.setSource($0)
        }

        func body(content: Content) -> some View {
            content
                .environment(\.multiViewHueRouter, router)
                .environment(\.hueFrameSourceSink, nil)
                .onAppear { router.selectNow(audioSlotID) }
                .onChange(of: audioSlotID) { _, slotID in router.select(slotID) }
                .modifier(HueSessionLifecycle { router.reset() })
        }
    }

    private struct MultiViewHueSlot: ViewModifier {
        let slotID: MultiViewSlot.ID

        @Environment(\.multiViewHueRouter) private var router

        func body(content: Content) -> some View {
            content.environment(\.hueFrameSourceSink, router.map { .multiViewSlot($0, slotID) })
        }
    }
#endif
