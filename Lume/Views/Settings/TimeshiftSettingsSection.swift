#if os(macOS)
    import SwiftUI

    struct TimeshiftSettingsSection: View {
        @AppStorage("player.timeshift.experimental") private var enabled = false
        @AppStorage(TimeshiftPreferences.durationKey) private var minutes = TimeshiftPreferences.defaultMinutes
        @AppStorage(TimeshiftPreferences.programmeTimelineKey) private var programmeTimeline = true
        @AppStorage(TimeshiftPreferences.measuredBitrateKey) private var measuredBitrate: Double = 0

        private var estimate: String {
            let bytes = TimeshiftPreferences.estimatedBytes(minutes: minutes, bitsPerSecond: measuredBitrate)
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        var body: some View {
            Section {
                Toggle("Local Live TV Buffer (Experimental)", isOn: $enabled)
                Picker("Pause Buffer Duration", selection: $minutes) {
                    ForEach(TimeshiftPreferences.minuteOptions, id: \.self) { value in
                        Text(Duration.seconds(value * 60).formatted(.units(allowed: [.minutes], width: .wide))).tag(value)
                    }
                }
                LabeledContent("Estimated Buffer Storage", value: estimate)
                Toggle("Limit Catch-up Timeline to Programme", isOn: $programmeTimeline)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Storage varies with channel quality. The estimate uses the last measured stream bitrate, or 8 Mbps before a measurement is available.")
                    Text("The buffer uses available disk space and a 30 GB safety limit. Reopen the player to apply a new duration.")
                    Text("Programme mode uses EPG duration for catch-up. Turn it off to use the duration reported by the provider.")
                }
            }
            .onAppear { minutes = TimeshiftPreferences.normalizedMinutes(minutes) }
        }
    }
#endif
