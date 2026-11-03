//
//  HueSensitivityNotice.swift
//  Lume
//
//  The light-sensitivity warning shown before Hue sync first turns on, from
//  Settings or the player's Hue menu. Confirming records that it was shown.
//

#if os(tvOS)
    import SwiftUI

    extension View {
        func hueSensitivityNotice(
            isPresented: Binding<Bool>,
            onConfirm: @escaping () -> Void,
            onCancel: @escaping () -> Void = {}
        ) -> some View {
            alert(Text("settings.hue.notice.title"), isPresented: isPresented) {
                Button("settings.hue.notice.confirm") {
                    PlayerSettings.Hue.markLightSensitivityNoticeShown()
                    onConfirm()
                }
                Button("settings.hue.notice.cancel", role: .cancel, action: onCancel)
            } message: {
                Text("settings.hue.notice.message")
            }
        }
    }
#endif
