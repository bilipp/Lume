//
//  ESPNSeason.swift
//  Lume
//
//  Optional season and calendar transport fields. Some sports send a calendar
//  of date strings instead of labelled phases; those entries carry no labels.
//

import Foundation

nonisolated struct ESPNSeason: Codable, Hashable {
    let year: Int?
    let type: Int?
    let displayName: String?
}

nonisolated struct ESPNWeek: Codable, Hashable {
    let number: Int?
    let text: String?
}

nonisolated struct ESPNNote: Codable, Hashable {
    let headline: String?
}

nonisolated struct ESPNCalendarEntry: Codable, Hashable {
    let label: String?
    let value: String?
    let entries: [ESPNCalendarEntry]?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let date = try? single.decode(String.self) {
            label = nil
            value = date
            entries = nil
        } else {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            label = try fields.decodeIfPresent(String.self, forKey: .label)
            value = try fields.decodeIfPresent(ESPNFlexibleValue.self, forKey: .value)?.stringValue
            entries = try fields.decodeIfPresent([ESPNCalendarEntry].self, forKey: .entries)
        }
    }

    private enum CodingKeys: String, CodingKey { case label, value, entries }
}

nonisolated extension ESPNClient {
    static func phaseLabel(event: ESPNEvent, context: ScoreboardContext) -> String? {
        guard let phase = event.season?.type ?? context.season?.type else { return nil }
        return context.calendar.first { $0.value == String(phase) }?.label
    }

    static func weekLabel(event: ESPNEvent, context: ScoreboardContext) -> String? {
        guard let week = event.week?.number ?? context.week?.number else { return nil }
        let phase = event.season?.type ?? context.season?.type
        return context.calendar.first { $0.value == phase.map(String.init) }?
            .entries?.first { $0.value == String(week) }?.label ?? event.week?.text ?? context.week?.text
    }
}
