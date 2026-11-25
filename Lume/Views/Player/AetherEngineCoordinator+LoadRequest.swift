#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    extension LumeAetherLoadRequest {
        /// The bridge's request for `plan`. A VOD resume starts at the saved
        /// position; live always joins at the edge.
        init(plan: AetherLoadPlan, media: PlayableMedia, audioStreamIndex: Int?) {
            self.init(
                url: media.url,
                startPosition: !media.isLive && media.startTime > 1 ? media.startTime : nil,
                audioStreamIndex: audioStreamIndex.flatMap { Int32(exactly: $0) },
                httpHeaders: plan.httpHeaders,
                isLive: plan.isLive,
                preferredAudioLanguages: audioStreamIndex == nil ? plan.preferredAudioLanguages : [],
                preferredDecodePath: plan.preferredDecodePath.rawValue,
                escalatesToSoftwarePath: plan.escalatesToSoftwarePath,
                deinterlaceMode: plan.deinterlaceMode.rawValue,
                deinterlaceFieldRate: plan.deinterlaceFieldRate.rawValue,
                usesFastZapLiveJoin: plan.liveJoinProfile == .fastZap,
                forwardBufferSegments: plan.forwardBufferSegments,
                probesize: plan.probesize,
                maxAnalyzeDuration: plan.maxAnalyzeDuration,
                nativeRemoteHLS: plan.nativeRemoteHLS,
                audioBridgeMode: plan.audioBridgeMode.rawValue,
                dolbyVisionHandling: plan.dolbyVisionHandling.rawValue,
                upscalesLowResolutionVideo: plan.upscalesLowResolutionVideo,
                upscalesFullHDVideo: plan.upscalesFullHDVideo,
                untaggedVideoColor: plan.untaggedVideoColor.rawValue,
                audioDelaySeconds: plan.audioDelaySeconds,
                prepareNativeSubtitles: plan.prepareNativeSubtitles,
                recognizesBitmapSubtitleText: plan.recognizesBitmapSubtitleText,
                maxConcurrentSourceRequests: plan.maxConcurrentSourceRequests,
                liveStartupGraceSeconds: plan.liveStartupGraceSeconds,
                writesDisplayCriteria: plan.writesDisplayCriteria,
                isSecondaryOutput: plan.sharedOutputRole == .secondary
            )
        }
    }

#endif
