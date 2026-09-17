//
//  ContentBulkActions.swift
//  Lume
//
//  The Show All / Hide All / Reset controls shared by the two Content Management
//  screens (the playlist's categories, and one category's channels). Hiding is
//  the sweeping direction — on a provider with thousands of channels it is the
//  only practical way to keep a handful — so it always confirms first.
//
//  The actions apply to whatever the screen is currently listing, which is what
//  makes "hide all, search for your country, show all matches" a two-step prune
//  instead of thousands of taps. Reset is the exception: it clears `customOrder`,
//  which is stamped densely across a whole group, so it always spans the full
//  group rather than a filtered subset.
//

import SwiftUI

extension View {
    /// Confirmation gate for a Hide All action. `title` names what's about to be
    /// hidden ("Hide All Categories?" / "Hide All Channels?").
    func hideAllConfirmation(
        _ title: LocalizedStringKey,
        isPresented: Binding<Bool>,
        hideAll: @escaping @MainActor () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button("Hide All", role: .destructive, action: hideAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything currently listed will be hidden from browsing. Use Show All to bring it back.")
        }
    }
}

#if os(tvOS)
    /// Section-header buttons for the tvOS management screens.
    struct ContentBulkActionButtons: View {
        let showAll: @MainActor () -> Void
        let hideAll: @MainActor () -> Void
        let reset: @MainActor () -> Void

        var body: some View {
            HStack(spacing: 12) {
                Button("Show All", action: showAll)
                Button("Hide All", action: hideAll)
                Button("Reset", action: reset)
            }
            .buttonStyle(TVSettingsActionButtonStyle())
        }
    }
#else
    /// A list row of bulk actions for the iOS / macOS management screens.
    ///
    /// Deliberately in the list rather than the toolbar: while a `.searchable`
    /// query is active iOS 26 hands the whole navigation bar over to the search
    /// field, so a toolbar button would disappear at exactly the moment the user
    /// wants to apply an action to the matches.
    struct ContentBulkActionsRow: View {
        let showAll: @MainActor () -> Void
        let hideAll: @MainActor () -> Void
        let reset: @MainActor () -> Void

        var body: some View {
            HStack(spacing: 0) {
                button("Show All", tint: .accentColor, action: showAll)
                separator
                button("Hide All", tint: .accentColor, action: hideAll)
                separator
                button("Reset", tint: .red, action: reset)
            }
            .font(.callout)
        }

        private var separator: some View {
            Divider().frame(height: 20)
        }

        private func button(
            _ title: LocalizedStringKey,
            tint: Color,
            action: @escaping @MainActor () -> Void
        ) -> some View {
            Button(action: action) {
                Text(title)
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }
#endif
