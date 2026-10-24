//
//  TVConnectedServicesView.swift
//  Lume
//
//  The tvOS Connected Services pane: every tracker integration this build has
//  credentials for, stacked in SettingsView's detail column. The iOS/macOS
//  counterpart is `ConnectedServicesView`, a list of drill-ins.
//

#if os(tvOS)

    import SwiftUI

    struct TVConnectedServicesView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 36) {
                if TraktService.shared.isConfigured {
                    TVTraktIntegrationView()
                }
                if SimklService.shared.isConfigured {
                    TVSimklIntegrationView()
                }
                if MDBListService.shared.isConfigured {
                    TVMDBListIntegrationView()
                }
            }
        }
    }

#endif
