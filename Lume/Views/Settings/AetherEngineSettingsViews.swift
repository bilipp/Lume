//
//  AetherEngineSettingsViews.swift
//  Lume
//
//  AetherEngine's curated option surface in Settings: a grouped `Form`
//  section plus the screen the Engines list pushes on iOS and macOS, and the
//  flat detail pane on tvOS. Every
//  control is backed directly by `@AppStorage` (raw values, never the enums
//  themselves), read back through `AetherEngineOptions.load(from:)` the next
//  time a stream starts.
//

import SwiftUI

#if !os(tvOS) && !os(visionOS)

    /// AetherEngine options as grouped `Form` sections.
    struct AetherEngineSettingsForm: View {
        private typealias Keys = PlayerSettings.Aether

        @AppStorage(Keys.decodePathKey) private var decodePath = Keys.decodePathDefault.rawValue
        @AppStorage(Keys.escalateToSoftwareKey) private var escalateToSoftware = Keys.escalateToSoftwareDefault
        @AppStorage(Keys.deinterlaceModeKey) private var deinterlaceMode = Keys.deinterlaceModeDefault.rawValue
        @AppStorage(Keys.deinterlaceFieldRateKey) private var deinterlaceFieldRate = Keys.deinterlaceFieldRateDefault.rawValue
        @AppStorage(Keys.upscaleLowResolutionKey) private var upscaleLowResolution = Keys.upscaleLowResolutionDefault
        @AppStorage(Keys.liveJoinProfileKey) private var liveJoinProfile = Keys.liveJoinProfileDefault.rawValue
        @AppStorage(Keys.forwardBufferSegmentsKey) private var forwardBufferSegments = Keys.forwardBufferSegmentsDefault
        @AppStorage(Keys.nativeRemoteHLSKey) private var nativeRemoteHLS = Keys.nativeRemoteHLSDefault
        @AppStorage(Keys.probeSizeKey) private var probeSize = Keys.probeSizeDefault.rawValue
        @AppStorage(Keys.analyzeDurationKey) private var analyzeDuration = Keys.analyzeDurationDefault.rawValue
        @AppStorage(Keys.audioBridgeModeKey) private var audioBridgeMode = Keys.audioBridgeModeDefault.rawValue
        @AppStorage(Keys.audioDelayKey) private var audioDelay = Keys.audioDelayDefault
        @AppStorage(Keys.dynamicRangeKey) private var dynamicRange = Keys.dynamicRangeDefault.rawValue
        @AppStorage(Keys.prepareNativeSubtitlesKey) private var prepareNativeSubtitles = Keys.prepareNativeSubtitlesDefault

        @State private var showResetConfirmation = false

        var body: some View {
            Section {
                Picker("Decoding", selection: $decodePath) {
                    ForEach(AetherDecodePath.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if decodePath == AetherDecodePath.automatic.rawValue {
                    Toggle("Fall Back to Software Decoding", isOn: $escalateToSoftware)
                }
                Picker("Deinterlace", selection: $deinterlaceMode) {
                    ForEach(AetherDeinterlaceMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if deinterlaceMode == AetherDeinterlaceMode.auto.rawValue {
                    Picker("Frame Rate", selection: $deinterlaceFieldRate) {
                        ForEach(AetherDeinterlaceFieldRate.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                Toggle("Upscale Low-Resolution Video", isOn: $upscaleLowResolution)
            } header: {
                Text("Video")
            } footer: {
                Text("Automatic decodes in hardware where the device supports the format; Software always uses the CPU. ")
                    + Text("Falling back retries a stream in software when the hardware decoder rejects it. ")
                    + Text("A doubled frame rate turns each interlaced field into its own frame for smoother motion.")
            }

            Section {
                Picker("Live Channel Start", selection: $liveJoinProfile) {
                    ForEach(AetherLiveJoinProfile.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Forward Buffer", selection: $forwardBufferSegments) {
                    ForEach(AetherForwardBufferPreset.values, id: \.self) {
                        Text(AetherForwardBufferPreset.label($0)).tag($0)
                    }
                }
                Toggle("Native HLS Playback", isOn: $nativeRemoteHLS)
                Picker("Probe Size", selection: $probeSize) {
                    ForEach(AetherProbeSize.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Analyze Duration", selection: $analyzeDuration) {
                    ForEach(AetherAnalyzeDuration.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } header: {
                Text("Network & Buffering")
            } footer: {
                Text("Fast Zap starts live channels sooner, but streams from unsteady servers may rebuffer more often. ")
                    + Text("The forward buffer sets how many segments are fetched ahead of playback. ")
                    + Text("Native HLS hands HLS streams straight to the system player; the forward buffer and live start settings don't apply to them. ")
                    + Text("Lower probe sizes and analyze durations start streams faster but can miss audio or subtitle tracks.")
            }

            Section {
                Picker("Audio Output", selection: $audioBridgeMode) {
                    ForEach(AetherAudioBridgeMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Audio Delay", selection: $audioDelay) {
                    ForEach(AetherAudioDelayPreset.values, id: \.self) {
                        Text(AetherAudioDelayPreset.label($0)).tag($0)
                    }
                }
                Picker("HDR", selection: $dynamicRange) {
                    ForEach(AetherDynamicRangeHandling.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("System Subtitle Tracks", isOn: $prepareNativeSubtitles)
            } header: {
                Text("Audio & Subtitles")
            } footer: {
                Text("Surround Compatible converts audio formats the system can't play as-is to lossy surround that every speaker setup accepts. ")
                    + Text("Lossless keeps full quality but needs a receiver that takes multichannel PCM. ")
                    + Text("A positive audio delay plays sound later. ")
                    + Text("HDR Base Layer Only skips the enhancement layer of layered HDR video. ")
                    + Text("System subtitle tracks keep text subtitles visible in Picture in Picture and on AirPlay. Applied the next time playback starts.")
            }

            Section {
                Button("Restore Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
            }
            .confirmationDialog(
                "Restore the default AetherEngine options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.Aether.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Dedicated screen wrapping the AetherEngine options, pushed from the
    /// Engines list so they are reachable regardless of the priority order.
    struct AetherEngineSettingsScreen: View {
        var body: some View {
            Form {
                AetherEngineSettingsForm()
            }
            .platformNavigationTitle("AetherEngine Options")
        }
    }

#endif

// MARK: - tvOS detail

#if os(tvOS)

    /// AetherEngine options for the tvOS settings detail pane.
    struct AetherEngineSettingsTVDetail: View {
        private typealias Keys = PlayerSettings.Aether

        @AppStorage(Keys.decodePathKey) private var decodePath = Keys.decodePathDefault.rawValue
        @AppStorage(Keys.escalateToSoftwareKey) private var escalateToSoftware = Keys.escalateToSoftwareDefault
        @AppStorage(Keys.deinterlaceModeKey) private var deinterlaceMode = Keys.deinterlaceModeDefault.rawValue
        @AppStorage(Keys.deinterlaceFieldRateKey) private var deinterlaceFieldRate = Keys.deinterlaceFieldRateDefault.rawValue
        @AppStorage(Keys.upscaleLowResolutionKey) private var upscaleLowResolution = Keys.upscaleLowResolutionDefault
        @AppStorage(Keys.matchContentKey) private var matchContent = Keys.matchContentDefault
        @AppStorage(Keys.liveJoinProfileKey) private var liveJoinProfile = Keys.liveJoinProfileDefault.rawValue
        @AppStorage(Keys.forwardBufferSegmentsKey) private var forwardBufferSegments = Keys.forwardBufferSegmentsDefault
        @AppStorage(Keys.nativeRemoteHLSKey) private var nativeRemoteHLS = Keys.nativeRemoteHLSDefault
        @AppStorage(Keys.probeSizeKey) private var probeSize = Keys.probeSizeDefault.rawValue
        @AppStorage(Keys.analyzeDurationKey) private var analyzeDuration = Keys.analyzeDurationDefault.rawValue
        @AppStorage(Keys.audioBridgeModeKey) private var audioBridgeMode = Keys.audioBridgeModeDefault.rawValue
        @AppStorage(Keys.audioDelayKey) private var audioDelay = Keys.audioDelayDefault
        @AppStorage(Keys.dynamicRangeKey) private var dynamicRange = Keys.dynamicRangeDefault.rawValue
        @AppStorage(Keys.prepareNativeSubtitlesKey) private var prepareNativeSubtitles = Keys.prepareNativeSubtitlesDefault

        @State private var showResetConfirmation = false

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("AetherEngine — Video")
                    TVOptionCycleRow(
                        title: "Decoding",
                        valueLabel: (AetherDecodePath(rawValue: decodePath) ?? Keys.decodePathDefault).label
                    ) { decodePath = PlayerOptionCycle.next(decodePath, in: AetherDecodePath.self) }
                    if decodePath == AetherDecodePath.automatic.rawValue {
                        TVOptionToggleRow(title: "Fall Back to Software Decoding", isOn: $escalateToSoftware)
                    }
                    TVOptionCycleRow(
                        title: "Deinterlace",
                        valueLabel: (AetherDeinterlaceMode(rawValue: deinterlaceMode) ?? Keys.deinterlaceModeDefault).label
                    ) { deinterlaceMode = PlayerOptionCycle.next(deinterlaceMode, in: AetherDeinterlaceMode.self) }
                    if deinterlaceMode == AetherDeinterlaceMode.auto.rawValue {
                        TVOptionCycleRow(
                            title: "Frame Rate",
                            valueLabel: (AetherDeinterlaceFieldRate(rawValue: deinterlaceFieldRate) ?? Keys.deinterlaceFieldRateDefault).label
                        ) { deinterlaceFieldRate = PlayerOptionCycle.next(deinterlaceFieldRate, in: AetherDeinterlaceFieldRate.self) }
                    }
                    TVOptionToggleRow(title: "Upscale Low-Resolution Video", isOn: $upscaleLowResolution)
                    TVOptionToggleRow(title: "Match Content", isOn: $matchContent)
                    Text("Match Content switches the TV to the video's frame rate and dynamic range. Previews and Multiview tiles never switch it.")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("AetherEngine — Network & Buffering")
                    TVOptionCycleRow(
                        title: "Live Channel Start",
                        valueLabel: (AetherLiveJoinProfile(rawValue: liveJoinProfile) ?? Keys.liveJoinProfileDefault).label
                    ) { liveJoinProfile = PlayerOptionCycle.next(liveJoinProfile, in: AetherLiveJoinProfile.self) }
                    TVOptionCycleRow(title: "Forward Buffer", valueLabel: AetherForwardBufferPreset.label(forwardBufferSegments)) {
                        forwardBufferSegments = PlayerOptionCycle.next(forwardBufferSegments, in: AetherForwardBufferPreset.values)
                    }
                    TVOptionToggleRow(title: "Native HLS Playback", isOn: $nativeRemoteHLS)
                    TVOptionCycleRow(
                        title: "Probe Size",
                        valueLabel: (AetherProbeSize(rawValue: probeSize) ?? Keys.probeSizeDefault).label
                    ) { probeSize = PlayerOptionCycle.next(probeSize, in: AetherProbeSize.self) }
                    TVOptionCycleRow(
                        title: "Analyze Duration",
                        valueLabel: (AetherAnalyzeDuration(rawValue: analyzeDuration) ?? Keys.analyzeDurationDefault).label
                    ) { analyzeDuration = PlayerOptionCycle.next(analyzeDuration, in: AetherAnalyzeDuration.self) }
                    (Text("Fast Zap starts live channels sooner, but streams from unsteady servers may rebuffer more often. ")
                        + Text("Native HLS hands HLS streams straight to the system player; the forward buffer and live start settings don't apply to them. ")
                        + Text("Lower probe sizes and analyze durations start streams faster but can miss audio or subtitle tracks."))
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                        .padding(.top, 6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("AetherEngine — Audio & Subtitles")
                    TVOptionCycleRow(
                        title: "Audio Output",
                        valueLabel: (AetherAudioBridgeMode(rawValue: audioBridgeMode) ?? Keys.audioBridgeModeDefault).label
                    ) { audioBridgeMode = PlayerOptionCycle.next(audioBridgeMode, in: AetherAudioBridgeMode.self) }
                    TVOptionCycleRow(title: "Audio Delay", valueLabel: AetherAudioDelayPreset.label(audioDelay)) {
                        audioDelay = PlayerOptionCycle.next(audioDelay, in: AetherAudioDelayPreset.values)
                    }
                    TVOptionCycleRow(
                        title: "HDR",
                        valueLabel: (AetherDynamicRangeHandling(rawValue: dynamicRange) ?? Keys.dynamicRangeDefault).label
                    ) { dynamicRange = PlayerOptionCycle.next(dynamicRange, in: AetherDynamicRangeHandling.self) }
                    TVOptionToggleRow(title: "System Subtitle Tracks", isOn: $prepareNativeSubtitles)
                }

                TVOptionResetRow(title: "Restore Defaults") { showResetConfirmation = true }
            }
            .confirmationDialog(
                "Restore the default AetherEngine options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.Aether.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

#endif
