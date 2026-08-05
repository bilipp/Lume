//
//  PlayerEngineSettingsViews.swift
//  Lume
//
//  The per-engine option surfaces shown in Settings. Each engine gets its own
//  dedicated screen, reachable from the Player section regardless of the engine
//  priority order. Two presentations share this file: grouped `Form` sections
//  for iOS/macOS, and the flat Apple-TV-style detail blocks for tvOS.
//
//  Every control is backed directly by `@AppStorage`, so changes persist
//  immediately and are read back by the engines via `VLCPlayerOptions` /
//  `KSPlayerOptions` the next time a stream starts.
//

import SwiftUI

// MARK: - iOS / macOS forms

#if !os(tvOS)

    /// VLCKit options as a grouped `Form` section.
    struct VLCEngineSettingsForm: View {
        @AppStorage(PlayerSettings.VLC.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.VLC.hardwareDecodeDefault
        @AppStorage(PlayerSettings.VLC.decodeThreadsKey) private var decodeThreads = PlayerSettings.VLC.decodeThreadsDefault
        @AppStorage(PlayerSettings.VLC.skipFramesKey) private var skipFrames = PlayerSettings.VLC.skipFramesDefault
        @AppStorage(PlayerSettings.VLC.dropLateFramesKey) private var dropLateFrames = PlayerSettings.VLC.dropLateFramesDefault
        @AppStorage(PlayerSettings.VLC.httpReconnectKey) private var httpReconnect = PlayerSettings.VLC.httpReconnectDefault
        @AppStorage(PlayerSettings.deinterlaceKey) private var deinterlace = PlayerSettings.deinterlaceDefault
        @AppStorage(PlayerSettings.VLC.deinterlaceModeKey) private var deinterlaceMode = VLCDeinterlaceMode.blend.rawValue
        @AppStorage(PlayerSettings.VLC.liveBufferKey) private var liveBuffer = PlayerSettings.VLC.liveBufferDefault
        @AppStorage(PlayerSettings.VLC.vodBufferKey) private var vodBuffer = PlayerSettings.VLC.vodBufferDefault
        @AppStorage(PlayerSettings.VLC.clockJitterKey) private var clockJitter = VLCClockJitter.auto.rawValue
        @AppStorage(PlayerSettings.VLC.clockSynchroKey) private var clockSynchro = VLCClockSynchro.automatic.rawValue

        @State private var showResetConfirmation = false

        var body: some View {
            Section {
                Toggle("Hardware Decoding", isOn: $hardwareDecode)

                Picker("Decode Threads", selection: $decodeThreads) {
                    ForEach(VLCDecodeThreads.allCases) { Text($0.label).tag($0.rawValue) }
                }

                Toggle("Skip Frames", isOn: $skipFrames)
                Toggle("Drop Late Frames", isOn: $dropLateFrames)
                Toggle("HTTP Reconnect", isOn: $httpReconnect)

                Toggle("Deinterlace Video", isOn: $deinterlace)
                if deinterlace {
                    Picker("Deinterlace Mode", selection: $deinterlaceMode) {
                        ForEach(VLCDeinterlaceMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }

                Picker("Live Buffer", selection: $liveBuffer) {
                    ForEach(VLCCachingPreset.values, id: \.self) { Text(VLCCachingPreset.label($0)).tag($0) }
                }
                Picker("On-Demand Buffer", selection: $vodBuffer) {
                    ForEach(VLCCachingPreset.values, id: \.self) { Text(VLCCachingPreset.label($0)).tag($0) }
                }

                Picker("Clock Jitter", selection: $clockJitter) {
                    ForEach(VLCClockJitter.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Clock Synchronisation", selection: $clockSynchro) {
                    ForEach(VLCClockSynchro.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("Applied the next time playback starts.")
            }

            Section {
                Button("Restore Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
            }
            .confirmationDialog(
                "Restore the default VLCKit options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.VLC.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Dedicated screen wrapping the VLCKit options, pushed from the Player
    /// settings section so every engine's options are reachable regardless of
    /// the priority order.
    struct VLCEngineSettingsScreen: View {
        var body: some View {
            Form {
                VLCEngineSettingsForm()
            }
            .platformNavigationTitle("VLCKit Options")
        }
    }

    /// KSPlayer options as a grouped `Form` section.
    struct KSEngineSettingsForm: View {
        @AppStorage(PlayerSettings.KSPlayer.primaryEngineKey) private var primaryEngine = KSPrimaryEngine.defaultValue.rawValue
        @AppStorage(PlayerSettings.KSPlayer.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.KSPlayer.hardwareDecodeDefault
        @AppStorage(PlayerSettings.KSPlayer.asyncDecompressionKey) private var asyncDecompression = PlayerSettings.KSPlayer.asyncDecompressionDefault
        @AppStorage(PlayerSettings.KSPlayer.secondOpenKey) private var secondOpen = PlayerSettings.KSPlayer.secondOpenDefault
        @AppStorage(PlayerSettings.KSPlayer.accurateSeekKey) private var accurateSeek = PlayerSettings.KSPlayer.accurateSeekDefault
        @AppStorage(PlayerSettings.KSPlayer.loopPlayKey) private var loopPlay = PlayerSettings.KSPlayer.loopPlayDefault
        @AppStorage(PlayerSettings.KSPlayer.systemProxyKey) private var systemProxy = PlayerSettings.KSPlayer.systemProxyDefault
        @AppStorage(PlayerSettings.KSPlayer.autoDeinterlaceKey) private var autoDeinterlace = PlayerSettings.KSPlayer.autoDeinterlaceDefault
        @AppStorage(PlayerSettings.KSPlayer.autoRotateKey) private var autoRotate = PlayerSettings.KSPlayer.autoRotateDefault
        @AppStorage(PlayerSettings.KSPlayer.adaptiveKey) private var adaptive = PlayerSettings.KSPlayer.adaptiveDefault
        @AppStorage(PlayerSettings.KSPlayer.noBufferKey) private var noBuffer = PlayerSettings.KSPlayer.noBufferDefault
        @AppStorage(PlayerSettings.KSPlayer.codecLowDelayKey) private var codecLowDelay = PlayerSettings.KSPlayer.codecLowDelayDefault
        @AppStorage(PlayerSettings.KSPlayer.autoPipKey) private var autoPip = PlayerSettings.KSPlayer.autoPipDefault
        @AppStorage(PlayerSettings.KSPlayer.autoSelectSubtitleKey) private var autoSelectSubtitle = PlayerSettings.KSPlayer.autoSelectSubtitleDefault
        @AppStorage(PlayerSettings.KSPlayer.liveBufferKey) private var liveBuffer = PlayerSettings.KSPlayer.liveBufferDefault
        @AppStorage(PlayerSettings.KSPlayer.vodBufferKey) private var vodBuffer = PlayerSettings.KSPlayer.vodBufferDefault
        @AppStorage(PlayerSettings.KSPlayer.maxBufferKey) private var maxBuffer = PlayerSettings.KSPlayer.maxBufferDefault

        @State private var showResetConfirmation = false

        var body: some View {
            Section {
                Picker("Decoder Engine", selection: $primaryEngine) {
                    ForEach(KSPrimaryEngine.allCases) { Text($0.label).tag($0.rawValue) }
                }

                Toggle("Hardware Decoding", isOn: $hardwareDecode)
                Toggle("Asynchronous Decompression", isOn: $asyncDecompression)
                Toggle("Codec Low Delay", isOn: $codecLowDelay)
                Toggle("Auto Deinterlace", isOn: $autoDeinterlace)
                Toggle("Auto Rotate", isOn: $autoRotate)
                Toggle("Adaptive Bitrate", isOn: $adaptive)
                Toggle("Accurate Seek", isOn: $accurateSeek)
                Toggle("Fast Open", isOn: $secondOpen)
                Toggle("Loop Playback", isOn: $loopPlay)
                Toggle("Auto-Select Subtitles", isOn: $autoSelectSubtitle)
                Toggle("Low Latency (No Buffer)", isOn: $noBuffer)
                Toggle("Use System HTTP Proxy", isOn: $systemProxy)
                Toggle("Automatic Picture in Picture", isOn: $autoPip)

                Picker("Live Buffer", selection: $liveBuffer) {
                    ForEach(KSBufferPreset.values, id: \.self) { Text(KSBufferPreset.label($0)).tag($0) }
                }
                Picker("On-Demand Buffer", selection: $vodBuffer) {
                    ForEach(KSBufferPreset.values, id: \.self) { Text(KSBufferPreset.label($0)).tag($0) }
                }
                Picker("Maximum Buffer", selection: $maxBuffer) {
                    ForEach(KSMaxBufferPreset.values, id: \.self) { Text(KSMaxBufferPreset.label($0)).tag($0) }
                }
            } footer: {
                Text("FFmpeg honours every option below for all streams. ")
                    + Text("AVPlayer is more efficient but ignores most of them — including buffering — for formats it plays natively, such as HLS. Applied the next time playback starts.")
            }

            Section {
                Button("Restore Defaults", role: .destructive) {
                    showResetConfirmation = true
                }
            }
            .confirmationDialog(
                "Restore the default KSPlayer options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.KSPlayer.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Dedicated screen wrapping the KSPlayer options, pushed from the Player
    /// settings section so every engine's options are reachable regardless of
    /// the priority order.
    struct KSEngineSettingsScreen: View {
        var body: some View {
            Form {
                KSEngineSettingsForm()
            }
            .platformNavigationTitle("KSPlayer Options")
        }
    }

    /// Lume Engine options as a grouped `Form` section.
    struct LumeEngineSettingsForm: View {
        @AppStorage(PlayerSettings.Lume.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.Lume.hardwareDecodeDefault
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
                Text("The buffers set how much decoded media is held before playback starts or resumes — raise them if high-bitrate 4K streams stutter. ")
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

    /// A flat toggle row matching the Apple-TV settings rows: shows On/Off and
    /// flips on Select.
    struct TVOptionToggleRow: View {
        let title: LocalizedStringKey
        @Binding var isOn: Bool

        var body: some View {
            Button { isOn.toggle() } label: {
                HStack(spacing: 16) {
                    Text(title)
                    Spacer(minLength: 0)
                    Text(isOn ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

    /// A flat row that cycles through a fixed set of choices on each Select,
    /// showing the current choice's label on the right. tvOS has no good inline
    /// picker, and a full sub-list per option would bury the settings, so the
    /// row advances to the next value in place.
    struct TVOptionCycleRow: View {
        let title: LocalizedStringKey
        let valueLabel: String
        let onAdvance: () -> Void

        var body: some View {
            Button(action: onAdvance) {
                HStack(spacing: 16) {
                    Text(title)
                    Spacer(minLength: 0)
                    Text(verbatim: valueLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

    /// VLCKit options for the tvOS settings detail pane.
    struct VLCEngineSettingsTVDetail: View {
        @AppStorage(PlayerSettings.VLC.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.VLC.hardwareDecodeDefault
        @AppStorage(PlayerSettings.VLC.decodeThreadsKey) private var decodeThreads = PlayerSettings.VLC.decodeThreadsDefault
        @AppStorage(PlayerSettings.VLC.skipFramesKey) private var skipFrames = PlayerSettings.VLC.skipFramesDefault
        @AppStorage(PlayerSettings.VLC.dropLateFramesKey) private var dropLateFrames = PlayerSettings.VLC.dropLateFramesDefault
        @AppStorage(PlayerSettings.VLC.httpReconnectKey) private var httpReconnect = PlayerSettings.VLC.httpReconnectDefault
        @AppStorage(PlayerSettings.deinterlaceKey) private var deinterlace = PlayerSettings.deinterlaceDefault
        @AppStorage(PlayerSettings.VLC.deinterlaceModeKey) private var deinterlaceMode = VLCDeinterlaceMode.blend.rawValue
        @AppStorage(PlayerSettings.VLC.liveBufferKey) private var liveBuffer = PlayerSettings.VLC.liveBufferDefault
        @AppStorage(PlayerSettings.VLC.vodBufferKey) private var vodBuffer = PlayerSettings.VLC.vodBufferDefault
        @AppStorage(PlayerSettings.VLC.clockJitterKey) private var clockJitter = VLCClockJitter.auto.rawValue
        @AppStorage(PlayerSettings.VLC.clockSynchroKey) private var clockSynchro = VLCClockSynchro.automatic.rawValue

        @State private var showResetConfirmation = false

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("VLCKit — Decoding")
                    TVOptionToggleRow(title: "Hardware Decoding", isOn: $hardwareDecode)
                    TVOptionCycleRow(
                        title: "Decode Threads",
                        valueLabel: (VLCDecodeThreads(rawValue: decodeThreads) ?? .auto).label
                    ) { decodeThreads = PlayerOptionCycle.next(decodeThreads, in: VLCDecodeThreads.self) }
                    TVOptionToggleRow(title: "Skip Frames", isOn: $skipFrames)
                    TVOptionToggleRow(title: "Drop Late Frames", isOn: $dropLateFrames)
                    TVOptionToggleRow(title: "Deinterlace Video", isOn: $deinterlace)
                    if deinterlace {
                        TVOptionCycleRow(
                            title: "Deinterlace Mode",
                            valueLabel: (VLCDeinterlaceMode(rawValue: deinterlaceMode) ?? .blend).label
                        ) { deinterlaceMode = PlayerOptionCycle.next(deinterlaceMode, in: VLCDeinterlaceMode.self) }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("VLCKit — Network & Buffering")
                    TVOptionToggleRow(title: "HTTP Reconnect", isOn: $httpReconnect)
                    TVOptionCycleRow(title: "Live Buffer", valueLabel: VLCCachingPreset.label(liveBuffer)) {
                        liveBuffer = PlayerOptionCycle.next(liveBuffer, in: VLCCachingPreset.values)
                    }
                    TVOptionCycleRow(title: "On-Demand Buffer", valueLabel: VLCCachingPreset.label(vodBuffer)) {
                        vodBuffer = PlayerOptionCycle.next(vodBuffer, in: VLCCachingPreset.values)
                    }
                    TVOptionCycleRow(
                        title: "Clock Jitter",
                        valueLabel: (VLCClockJitter(rawValue: clockJitter) ?? .auto).label
                    ) { clockJitter = PlayerOptionCycle.next(clockJitter, in: VLCClockJitter.self) }
                    TVOptionCycleRow(
                        title: "Clock Synchronisation",
                        valueLabel: (VLCClockSynchro(rawValue: clockSynchro) ?? .automatic).label
                    ) { clockSynchro = PlayerOptionCycle.next(clockSynchro, in: VLCClockSynchro.self) }
                }

                TVOptionResetRow(title: "Restore Defaults") { showResetConfirmation = true }
            }
            .confirmationDialog(
                "Restore the default VLCKit options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.VLC.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// KSPlayer options for the tvOS settings detail pane.
    struct KSEngineSettingsTVDetail: View {
        @AppStorage(PlayerSettings.KSPlayer.primaryEngineKey) private var primaryEngine = KSPrimaryEngine.defaultValue.rawValue
        @AppStorage(PlayerSettings.KSPlayer.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.KSPlayer.hardwareDecodeDefault
        @AppStorage(PlayerSettings.KSPlayer.asyncDecompressionKey) private var asyncDecompression = PlayerSettings.KSPlayer.asyncDecompressionDefault
        @AppStorage(PlayerSettings.KSPlayer.secondOpenKey) private var secondOpen = PlayerSettings.KSPlayer.secondOpenDefault
        @AppStorage(PlayerSettings.KSPlayer.accurateSeekKey) private var accurateSeek = PlayerSettings.KSPlayer.accurateSeekDefault
        @AppStorage(PlayerSettings.KSPlayer.loopPlayKey) private var loopPlay = PlayerSettings.KSPlayer.loopPlayDefault
        @AppStorage(PlayerSettings.KSPlayer.systemProxyKey) private var systemProxy = PlayerSettings.KSPlayer.systemProxyDefault
        @AppStorage(PlayerSettings.KSPlayer.autoDeinterlaceKey) private var autoDeinterlace = PlayerSettings.KSPlayer.autoDeinterlaceDefault
        @AppStorage(PlayerSettings.KSPlayer.autoRotateKey) private var autoRotate = PlayerSettings.KSPlayer.autoRotateDefault
        @AppStorage(PlayerSettings.KSPlayer.adaptiveKey) private var adaptive = PlayerSettings.KSPlayer.adaptiveDefault
        @AppStorage(PlayerSettings.KSPlayer.noBufferKey) private var noBuffer = PlayerSettings.KSPlayer.noBufferDefault
        @AppStorage(PlayerSettings.KSPlayer.codecLowDelayKey) private var codecLowDelay = PlayerSettings.KSPlayer.codecLowDelayDefault
        @AppStorage(PlayerSettings.KSPlayer.autoPipKey) private var autoPip = PlayerSettings.KSPlayer.autoPipDefault
        @AppStorage(PlayerSettings.KSPlayer.autoSelectSubtitleKey) private var autoSelectSubtitle = PlayerSettings.KSPlayer.autoSelectSubtitleDefault
        @AppStorage(PlayerSettings.KSPlayer.liveBufferKey) private var liveBuffer = PlayerSettings.KSPlayer.liveBufferDefault
        @AppStorage(PlayerSettings.KSPlayer.vodBufferKey) private var vodBuffer = PlayerSettings.KSPlayer.vodBufferDefault
        @AppStorage(PlayerSettings.KSPlayer.maxBufferKey) private var maxBuffer = PlayerSettings.KSPlayer.maxBufferDefault

        @State private var showResetConfirmation = false

        var body: some View {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("KSPlayer — Decoding")
                    TVOptionCycleRow(
                        title: "Decoder Engine",
                        valueLabel: (KSPrimaryEngine(rawValue: primaryEngine) ?? .defaultValue).label
                    ) { primaryEngine = PlayerOptionCycle.next(primaryEngine, in: KSPrimaryEngine.self) }
                    TVOptionToggleRow(title: "Hardware Decoding", isOn: $hardwareDecode)
                    TVOptionToggleRow(title: "Asynchronous Decompression", isOn: $asyncDecompression)
                    TVOptionToggleRow(title: "Codec Low Delay", isOn: $codecLowDelay)
                    TVOptionToggleRow(title: "Auto Deinterlace", isOn: $autoDeinterlace)
                    TVOptionToggleRow(title: "Auto Rotate", isOn: $autoRotate)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("KSPlayer — Playback")
                    TVOptionToggleRow(title: "Adaptive Bitrate", isOn: $adaptive)
                    TVOptionToggleRow(title: "Accurate Seek", isOn: $accurateSeek)
                    TVOptionToggleRow(title: "Fast Open", isOn: $secondOpen)
                    TVOptionToggleRow(title: "Loop Playback", isOn: $loopPlay)
                    TVOptionToggleRow(title: "Auto-Select Subtitles", isOn: $autoSelectSubtitle)
                    TVOptionToggleRow(title: "Automatic Picture in Picture", isOn: $autoPip)
                    TVOptionToggleRow(title: "Use System HTTP Proxy", isOn: $systemProxy)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TVSettingsSectionLabel("KSPlayer — Buffering")
                    TVOptionToggleRow(title: "Low Latency (No Buffer)", isOn: $noBuffer)
                    TVOptionCycleRow(title: "Live Buffer", valueLabel: KSBufferPreset.label(liveBuffer)) {
                        liveBuffer = PlayerOptionCycle.next(liveBuffer, in: KSBufferPreset.values)
                    }
                    TVOptionCycleRow(title: "On-Demand Buffer", valueLabel: KSBufferPreset.label(vodBuffer)) {
                        vodBuffer = PlayerOptionCycle.next(vodBuffer, in: KSBufferPreset.values)
                    }
                    TVOptionCycleRow(title: "Maximum Buffer", valueLabel: KSMaxBufferPreset.label(maxBuffer)) {
                        maxBuffer = PlayerOptionCycle.next(maxBuffer, in: KSMaxBufferPreset.values)
                    }
                }

                TVOptionResetRow(title: "Restore Defaults") { showResetConfirmation = true }
            }
            .confirmationDialog(
                "Restore the default KSPlayer options?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore Defaults", role: .destructive) {
                    PlayerSettings.KSPlayer.resetToDefaults()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// Lume Engine options for the tvOS settings detail pane.
    struct LumeEngineSettingsTVDetail: View {
        @AppStorage(PlayerSettings.Lume.hardwareDecodeKey) private var hardwareDecode = PlayerSettings.Lume.hardwareDecodeDefault
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

    /// A flat destructive-styled row used to trigger a reset on tvOS.
    struct TVOptionResetRow: View {
        let title: LocalizedStringKey
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 16) {
                    Text(title)
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(TVSettingsRowButtonStyle())
        }
    }

    /// Helpers for cycling tvOS option rows to their next choice.
    enum PlayerOptionCycle {
        /// Advance to the next value in a preset list, wrapping around.
        static func next(_ current: Int, in values: [Int]) -> Int {
            guard let index = values.firstIndex(of: current) else { return values.first ?? current }
            return values[(index + 1) % values.count]
        }

        /// Advance to the next case of an `Int`-raw enum, wrapping around.
        static func next<T: CaseIterable & RawRepresentable>(_ current: Int, in _: T.Type) -> Int where T.RawValue == Int {
            let all = Array(T.allCases)
            guard let index = all.firstIndex(where: { $0.rawValue == current }) else {
                return all.first?.rawValue ?? current
            }
            return all[(index + 1) % all.count].rawValue
        }

        /// Advance to the next case of a `String`-raw enum, wrapping around.
        static func next<T: CaseIterable & RawRepresentable>(_ current: String, in _: T.Type) -> String where T.RawValue == String {
            let all = Array(T.allCases)
            guard let index = all.firstIndex(where: { $0.rawValue == current }) else {
                return all.first?.rawValue ?? current
            }
            return all[(index + 1) % all.count].rawValue
        }
    }

#endif
