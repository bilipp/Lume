//
//  CastLabels.swift
//  Lume
//
//  Strings the casting remote and the mini-controller share.
//

#if os(iOS)
    import Foundation

    enum CastLabels {
        static let stop = LocalizedStringResource(
            "player.cast.stop",
            defaultValue: "Stop Casting",
            comment: "Player › Casting: button that stops the Chromecast and plays the stream on this device again."
        )

        /// "Casting to <device>", or "Casting" for a receiver with no name.
        static func casting(deviceName: String?) -> LocalizedStringResource {
            guard let name = deviceName else {
                return LocalizedStringResource(
                    "player.cast.casting",
                    defaultValue: "Casting",
                    comment: "Player › Casting: status shown while a Chromecast that reports no name plays the stream."
                )
            }
            return LocalizedStringResource(
                "player.cast.casting-to",
                defaultValue: "Casting to \(name)",
                comment: "Player › Casting: status shown while a Chromecast plays the stream. The argument is the Chromecast's name."
            )
        }
    }
#endif
