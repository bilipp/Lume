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

        /// ESPN's schedule history is what a replay can be matched against;
        /// a generation of seasons covers it, newest first.
        private var thisYear: Int {
            Calendar.current.component(.year, from: Date())
        }

        var body: some View {
            Section(title) {
                Picker("Year", selection: component(.year)) {
                    ForEach((thisYear - 25 ... thisYear).reversed(), id: \.self) { Text(verbatim: String($0)).tag($0) }
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
