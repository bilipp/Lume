//
//  XtreamLoginHint.swift
//  Lume
//
//  Shown while adding an m3u playlist whose URL turns out to be an Xtream
//  `get.php` link.
//

import SwiftUI

/// The advisory for an m3u URL that is really an Xtream `get.php` endpoint,
/// plus the button that adds the provider as an Xtream playlist instead.
///
/// Adding always creates a *new* playlist from the credentials the URL carries;
/// an existing m3u playlist is never converted in place, because the two
/// pipelines disagree on content identity (see `XtreamCredentialsHint`).
struct XtreamLoginHint: View {
    let isLoading: Bool
    let add: () -> Void

    /// Non-interactive on purpose, so on tvOS only the button takes focus.
    private var message: some View {
        Label {
            Text("This is an Xtream provider link. It works as an m3u playlist, or add the provider as an Xtream login instead — Xtream syncs far less data for the same catalog.")
        } icon: {
            Image(systemName: "info.circle.fill")
        }
        .foregroundStyle(.secondary)
    }

    private var button: some View {
        Button("Add as Xtream Login", action: add)
            .disabled(isLoading)
    }

    var body: some View {
        #if os(tvOS)
            VStack(alignment: .leading, spacing: 16) {
                message
                    .font(.system(size: TVSettingsMetrics.secondaryFontSize))
                button
                    .buttonStyle(TVSettingsActionButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
            message
                .font(.callout)
            button
        #endif
    }
}
