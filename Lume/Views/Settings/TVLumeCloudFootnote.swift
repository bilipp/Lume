//
//  TVLumeCloudFootnote.swift
//  Lume
//

#if os(tvOS)

    import SwiftUI

    extension View {
        /// The Lume Cloud steps' explanatory or error line under a row, inset
        /// to line up with the row labels.
        func tvLumeCloudFootnote(isError: Bool = false) -> some View {
            font(.system(size: 22))
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
        }
    }

#endif
