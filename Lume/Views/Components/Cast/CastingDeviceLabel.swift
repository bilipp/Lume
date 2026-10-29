//
//  CastingDeviceLabel.swift
//  Lume
//

#if os(iOS)
    import SwiftUI

    /// "Casting to <device>". Its own leaf so a connection change re-renders
    /// only this line; the caller sets its font and style.
    struct CastingDeviceLabel: View {
        let castService: CastService

        var body: some View {
            Text(CastLabels.casting(deviceName: castService.chromecastDeviceName))
        }
    }
#endif
