//
//  TVTabBarEntryCatcher.swift
//  Lume
//
//  An invisible, full-width 1 pt band just below the tvOS tab bar. Down from
//  any tab item overlaps it, so it catches the move a narrow or off-centre
//  focus target would miss and hands it on. Callers place it vertically —
//  the gap under the tab bar depends on the screen's own layout.
//

#if os(tvOS)
    import SwiftUI

    struct TVTabBarEntryCatcher: View {
        /// Only while focus is outside the screen, so Up from its top row
        /// still reaches the tab bar.
        let isEnabled: Bool
        let onEntry: () -> Void

        @FocusState private var isFocused: Bool

        var body: some View {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                .focusable(isEnabled)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    guard focused else { return }
                    // Same-frame focus writes from a focus callback get dropped.
                    Task { @MainActor in onEntry() }
                }
        }
    }
#endif
