//
//  TVWhatsNewSettingsSection.swift
//  Lume
//
//  The About pane's way into the release history on tvOS. Standalone so it
//  owns the cover's presentation state.
//

import SwiftUI

#if os(tvOS)
    struct TVWhatsNewSettingsSection: View {
        @State private var showsHistory = false

        var body: some View {
            Button {
                showsHistory = true
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .medium))
                    Text("What’s New", tableName: "WhatsNew")
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle(isDestructive: false))
            .fullScreenCover(isPresented: $showsHistory) {
                WhatsNewHistoryView()
            }
        }
    }
#endif
