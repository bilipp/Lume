//
//  SportsReplayDatePicker.swift
//  Lume
//
//  tvOS has no DatePicker. Calendar-component pickers provide the same custom
//  range selection using focusable system controls.
//

#if os(tvOS)
    import SwiftUI

    struct SportsReplayDatePicker: View {
        let title: LocalizedStringKey
        @Binding var date: Date

        var body: some View {
            Section(title) {
                Picker("Year", selection: component(.year)) {
                    ForEach(1900 ... Calendar.current.component(.year, from: Date()), id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                Picker("Month", selection: component(.month)) {
                    ForEach(1 ... 12, id: \.self) { Text(verbatim: Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                }
                Picker("Day", selection: component(.day)) {
                    ForEach(Array(Calendar.current.range(of: .day, in: .month, for: date) ?? 1 ..< 29), id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
            }
        }

        private func component(_ component: Calendar.Component) -> Binding<Int> {
            Binding {
                Calendar.current.component(component, from: date)
            } set: { value in
                var parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                parts.setValue(value, for: component)
                if let candidate = Calendar.current.date(from: parts) { date = candidate }
            }
        }
    }
#endif
