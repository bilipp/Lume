//
//  TVLumeCloudActionRow.swift
//  Lume
//

#if os(tvOS)

    import SwiftUI

    /// An icon row button in the tvOS Lume Cloud steps, with a spinner while
    /// its action runs.
    struct TVLumeCloudActionRow: View {
        let title: LocalizedStringKey
        let systemImage: String
        let isBusy: Bool
        let action: () -> Void

        init(_ title: LocalizedStringKey, systemImage: String, isBusy: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.isBusy = isBusy
            self.action = action
        }

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .medium))
                    Text(title)
                    Spacer(minLength: 0)
                    if isBusy { ProgressView() }
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

#endif
