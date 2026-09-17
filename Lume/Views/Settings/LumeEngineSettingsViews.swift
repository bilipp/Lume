//
//  LumeEngineSettingsViews.swift
//  Lume
//
//  The Lume Engine's option surface in Settings, split out of
//  `PlayerEngineSettingsViews.swift` so the shared file stays under the
//  file-length limit. Same two presentations as the other engines: a grouped
//  `Form` section for iOS/macOS and the flat Apple-TV-style detail block for
//  tvOS.
//
//  Every control is backed directly by `@AppStorage`, read back by the
//  coordinator through `LumeEngineOptions` the next time a stream starts.
//

import SwiftUI

// MARK: - iOS / macOS form

#if !os(tvOS)

    /// Lume Engine options as a grouped `Form` section.
    struct LumeEngineSettingsForm: View {
        @AppStorage(PlayerSettings.Lume.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.Lume.hardwareDecodeDefault
        @AppStorage(PlayerSettings.Lume.deinterlaceModeKey) private var deinterlaceMode = LumeDeinterlaceMode.defaultValue.rawValue
        @AppStorage(PlayerSettings.Lume.deinterlaceRateKey) private var deinterlaceRate = LumeDeinterlaceRate.defaultValue.rawValue
        @AppStorage(PlayerSettings.Lume.httpReconnectKey) private var httpReconnect = PlayerSettings.Lume.httpReconnectDefault
        @AppStorage(PlayerSettings.Lume.liveBufferKey) private var liveBuffer = PlayerSettings.Lume.liveBufferDefault
        @AppStorage(PlayerSettings.Lume.vodBufferKey) private var vodBuffer = PlayerSettings.Lume.vodBufferDefault
        @AppStorage(PlayerSettings.Lume.videoQueueDepthKey) private var videoQueueDepth = PlayerSettings.Lume.videoQueueDepthDefault
        @AppStorage(PlayerSettings.Lume.audioQueueDepthKey) private var audioQueueDepth = PlayerSettings.Lume.audioQueueDepthDefault
        @AppStorage(PlayerSettings.Lume.stallThresholdKey) private var stallThreshold = PlayerSettings.Lume.stallThresholdDefault
        @AppStorage(PlayerSettings.Lume.ioTimeoutKey) private var ioTimeout = LumeIOTimeout.defaultValue.rawValue
        @AppStorage(PlayerSettings.Lume.probeSizeKey) private var probeSize = LumeProbeSize.auto.rawValue
        @AppStorage(PlayerSettings.Lume.analyzeDurationKey) private var analyzeDuration = LumeAnalyzeDuration.auto.rawValue

        @State private var showResetConfirmation = false

        var body: some View {
            Section {
                Toggle("Hardware Decoding", isOn: $hardwareDecode)

                Picker("Deinterlace", selection: $deinterlaceMode) {
                    ForEach(LumeDeinterlaceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if deinterlaceMode != LumeDeinterlaceMode.off.rawValue {
                    Picker("Frame Rate", selection: $deinterlaceRate) {
                        ForEach(LumeDeinterlaceRate.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }

                Picker("Video Queue Depth", selection: $videoQueueDepth) {
                    ForEach(LumeVideoQueuePreset.values, id: \.self) { Text(LumeVideoQueuePreset.label($0)).tag($0) }
                }
                Picker("Audio Queue Depth", selection: $audioQueueDepth) {
                    ForEach(LumeAudioQueuePreset.values, id: \.self) { Text(LumeAudioQueuePreset.label($0)).tag($0) }
                }

                Toggle("HTTP Reconnect", isOn: $httpReconnect)

                Picker("Live Buffer", selection: $liveBuffer) {
                    ForEach(LumeBufferPreset.values, id: \.self) { Text(LumeBufferPreset.label($0)).tag($0) }
                }
                Picker("On-Demand Buffer", selection: $vodBuffer) {
                    ForEach(LumeBufferPreset.values, id: \.self) { Text(LumeBufferPreset.label($0)).tag($0) }
                }

                Picker("Stall Detection", selection: $stallThreshold) {
                    ForEach(LumeStallThresholdPreset.values, id: \.self) { Text(LumeStallThresholdPreset.label($0)).tag($0) }
                }
                Picker("Network Timeout", selection: $ioTimeout) {
                    ForEach(LumeIOTimeout.allCases) { Text($0.label).tag($0.rawValue) }
                }

                Picker("Probe Size", selection: $probeSize) {
                    ForEach(LumeProbeSize.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Analyze Duration", selection: $analyzeDuration) {
                    ForEach(LumeAnalyzeDuration.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("Deinterlacing removes the combing interlaced broadcasts — most live sport — show on motion, without giving up hardware decoding. ")
                    + Text("Automatic filters only streams that report interlaced frames; choose Always for providers that don't. Doubling the frame rate smooths motion at a higher cost. ")
                    + Text("The buffers set how much decoded media is held before playback starts or resumes — raise them if high-bitrate 4K streams stutter. ")
                    + Text("Queue depths trade memory for smoothness: decoded 4K video frames are large, so raise the video queue cautiously. Applied the next time playback starts.")
            }

            Section {
                Button("Restore Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
            }
            .confirmationDialog(
                "Restore the default Lume Engine options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.Lume.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Dedicated screen wrapping the Lume Engine options, pushed from the Player
    /// settings section so every engine's options are reachable regardless of
    /// the priority order.
    struct LumeEngineSettingsScreen: View {
        var body: some View {
            Form {
                LumeEngineSettingsForm()
            }
            .platformNavigationTitle("Lume Engine Options")
        }
    }

#endif

// MARK: - tvOS detail

#if os(tvOS)

    /// Lume Engine options for the tvOS settings detail pane.
    struct LumeEngineSettingsTVDetail: View {
        @AppStorage(PlayerSettings.Lume.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.Lume.hardwareDecodeDefault
        @AppStorage(PlayerSettings.Lume.deinterlaceModeKey) private var deinterlaceMode = LumeDeinterlaceMode.defaultValue.rawValue
        @AppStorage(PlayerSettings.Lume.deinterlaceRateKey) private var deinterlaceRate = LumeDeinterlaceRate.defaultValue.rawValue
        @AppStorage(PlayerSettings.Lume.httpReconnectKey) private var httpReconnect = PlayerSettings.Lume.httpReconnectDefault
        @AppStorage(PlayerSettings.Lume.liveBufferKey) private var liveBuffer = PlayerSettings.Lume.liveBufferDefault
        @AppStorage(PlayerSettings.Lume.vodBufferKey) private var vodBuffer = PlayerSettings.Lume.vodBufferDefault
        @AppStorage(PlayerSettings.Lume.videoQueueDepthKey) private var videoQueueDepth = PlayerSettings.Lume.videoQueueDepthDefault
        @AppStorage(PlayerSettings.Lume.audioQueueDepthKey) private var audioQueueDepth = PlayerSettings.Lume.audioQueueDepthDefault
        @AppStorage(PlayerSettings.Lume.stallThresholdKey) private var stallThreshold = PlayerSettings.Lume.stallThresholdDefault
        @AppStorage(PlayerSettings.Lume.ioTimeoutKey) private var ioTimeout = LumeIOTimeout.defaultValue.rawValue
        @AppStorage(PlayerSettings.Lume.probeSizeKey) private var probeSize = LumeProbeSize.auto.rawValue
        @AppStorage(PlayerSettings.Lume.analyzeDurationKey) private var analyzeDuration = LumeAnalyzeDuration.auto.rawValue

        @State private var showResetConfirmation = false

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Lume Engine — Decoding")
                    TVOptionToggleRow(title: "Hardware Decoding", isOn: $hardwareDecode)
                    TVOptionCycleRow(
                        title: "Deinterlace",
                        valueLabel: (LumeDeinterlaceMode(rawValue: deinterlaceMode) ?? .defaultValue).label
                    ) { deinterlaceMode = PlayerOptionCycle.next(deinterlaceMode, in: LumeDeinterlaceMode.self) }
                    if deinterlaceMode != LumeDeinterlaceMode.off.rawValue {
                        TVOptionCycleRow(
                            title: "Frame Rate",
                            valueLabel: (LumeDeinterlaceRate(rawValue: deinterlaceRate) ?? .defaultValue).label
                        ) { deinterlaceRate = PlayerOptionCycle.next(deinterlaceRate, in: LumeDeinterlaceRate.self) }
                    }
                    TVOptionCycleRow(title: "Video Queue Depth", valueLabel: LumeVideoQueuePreset.label(videoQueueDepth)) {
                        videoQueueDepth = PlayerOptionCycle.next(videoQueueDepth, in: LumeVideoQueuePreset.values)
                    }
                    TVOptionCycleRow(title: "Audio Queue Depth", valueLabel: LumeAudioQueuePreset.label(audioQueueDepth)) {
                        audioQueueDepth = PlayerOptionCycle.next(audioQueueDepth, in: LumeAudioQueuePreset.values)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Lume Engine — Network & Buffering")
                    TVOptionToggleRow(title: "HTTP Reconnect", isOn: $httpReconnect)
                    TVOptionCycleRow(title: "Live Buffer", valueLabel: LumeBufferPreset.label(liveBuffer)) {
                        liveBuffer = PlayerOptionCycle.next(liveBuffer, in: LumeBufferPreset.values)
                    }
                    TVOptionCycleRow(title: "On-Demand Buffer", valueLabel: LumeBufferPreset.label(vodBuffer)) {
                        vodBuffer = PlayerOptionCycle.next(vodBuffer, in: LumeBufferPreset.values)
                    }
                    TVOptionCycleRow(title: "Stall Detection", valueLabel: LumeStallThresholdPreset.label(stallThreshold)) {
                        stallThreshold = PlayerOptionCycle.next(stallThreshold, in: LumeStallThresholdPreset.values)
                    }
                    TVOptionCycleRow(
                        title: "Network Timeout",
                        valueLabel: (LumeIOTimeout(rawValue: ioTimeout) ?? .defaultValue).label
                    ) { ioTimeout = PlayerOptionCycle.next(ioTimeout, in: LumeIOTimeout.self) }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("Lume Engine — Stream Analysis")
                    TVOptionCycleRow(
                        title: "Probe Size",
                        valueLabel: (LumeProbeSize(rawValue: probeSize) ?? .auto).label
                    ) { probeSize = PlayerOptionCycle.next(probeSize, in: LumeProbeSize.self) }
                    TVOptionCycleRow(
                        title: "Analyze Duration",
                        valueLabel: (LumeAnalyzeDuration(rawValue: analyzeDuration) ?? .auto).label
                    ) { analyzeDuration = PlayerOptionCycle.next(analyzeDuration, in: LumeAnalyzeDuration.self) }
                }

                TVOptionResetRow(title: "Restore Defaults") { showResetConfirmation = true }
            }
            .confirmationDialog(
                "Restore the default Lume Engine options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.Lume.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

#endif
