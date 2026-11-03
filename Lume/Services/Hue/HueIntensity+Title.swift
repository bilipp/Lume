//
//  HueIntensity+Title.swift
//  Lume
//

#if os(tvOS)
    import Foundation

    nonisolated extension HueIntensity {
        var settingsTitle: String {
            switch self {
            case .off: String(localized: "settings.hue.intensity.off", defaultValue: "Off")
            case .subtle: String(localized: "settings.hue.intensity.subtle", defaultValue: "Subtle")
            case .moderate: String(localized: "settings.hue.intensity.moderate", defaultValue: "Moderate")
            case .high: String(localized: "settings.hue.intensity.high", defaultValue: "High")
            case .intense: String(localized: "settings.hue.intensity.intense", defaultValue: "Intense")
            }
        }
    }
#endif
