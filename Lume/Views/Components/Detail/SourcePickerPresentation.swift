//
//  SourcePickerPresentation.swift
//  Lume
//

import SwiftUI

extension View {
    /// Presents a source picker as a sheet, full screen on tvOS.
    func sourcePickerPresentation<Item: Identifiable>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        #if os(tvOS)
            fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #else
            sheet(item: item, onDismiss: onDismiss) { content($0).sourcePickerSheetFrame() }
        #endif
    }

    /// ``sourcePickerPresentation(item:onDismiss:content:)`` driven by a flag.
    func sourcePickerPresentation(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        #if os(tvOS)
            fullScreenCover(isPresented: isPresented, content: content)
        #else
            sheet(isPresented: isPresented) { content().sourcePickerSheetFrame() }
        #endif
    }
}

private extension View {
    @ViewBuilder
    func sourcePickerSheetFrame() -> some View {
        #if os(macOS)
            // A frameless macOS sheet collapses its scroll view to zero.
            frame(minWidth: 520, idealWidth: 640, minHeight: 460, idealHeight: 620)
        #else
            self
        #endif
    }
}
