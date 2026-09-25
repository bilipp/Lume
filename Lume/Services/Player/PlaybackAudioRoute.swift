import Foundation
import OSLog

#if os(iOS) || os(tvOS)
    import AVFoundation
#elseif os(macOS)
    import CoreAudio
#endif

/// The app-owned playback audio session, and the output width it negotiated.
///
/// KSPlayer and VLCKit configure their own session; LumeEngine by design never
/// touches global audio state, so widening the route — and telling the engine
/// how wide it ended up — is the app's job.
@MainActor
enum PlaybackAudioRoute {
    private enum Activation {
        case stereo
        case widened
    }

    private static var activation: Activation?
    private static var grantedChannels: Int?

    /// Activates `.playback` / `.moviePlayback`, asks the route for its full
    /// channel width and returns what was actually granted; on macOS, where
    /// there is no audio session, it reports the default output device's own
    /// width instead. `nil` means stereo — nothing worth stating.
    ///
    /// Idempotent: repeat calls return the width resolved by the first one, so
    /// the player view and `LumeEngineCoordinator.makeConfiguration` may both
    /// call it in either order.
    @discardableResult
    static func activateForPlayback() -> Int? {
        #if os(iOS) || os(tvOS)
            if activation == .widened {
                return grantedChannels
            }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            // Activate BEFORE asking how wide the route is.
            // `maximumOutputNumberOfChannels` describes the *current* route,
            // and an inactive session reports the pre-activation default of 2
            // even when the HDMI sink takes 5.1/7.1. Reading it first made the
            // `> 2` guard fail on an Apple TV wired to a surround receiver, so
            // the session was never widened, LumeEngine correctly sized its
            // downmix to the 2 channels on offer, and a 5.1 E-AC-3 JOC track
            // reached the receiver as stereo LPCM. See issue #207.
            try? session.setActive(true, options: [])
            let maxChannels = session.maximumOutputNumberOfChannels
            if maxChannels > 2 {
                try? session.setPreferredOutputNumberOfChannels(maxChannels)
            }
            let granted = negotiatedWidth(granted: session.outputNumberOfChannels, maximum: maxChannels)
            activation = .widened
            grantedChannels = granted
            let route = session.currentRoute.outputs
                .map { "\($0.portType.rawValue)(\($0.channels?.count ?? 0)ch)" }
                .joined(separator: "+")
            let negotiated = granted.map(String.init) ?? "stereo"
            Logger.player.info("""
            Audio session active: route=\(route, privacy: .public) \
            outputChannels=\(session.outputNumberOfChannels) \
            maxChannels=\(maxChannels) sampleRate=\(session.sampleRate) \
            negotiatedWidth=\(negotiated, privacy: .public)
            """)
            return granted
        #elseif os(macOS)
            if activation == .widened {
                return grantedChannels
            }
            let width = defaultOutputDeviceWidth()
            activation = .widened
            grantedChannels = width
            let negotiated = width.map(String.init) ?? "stereo"
            Logger.player.info("Audio output device: negotiatedWidth=\(negotiated, privacy: .public)")
            return width
        #else
            return nil
        #endif
    }

    /// Activates the same category without requesting the route's full width.
    static func activateStereo() {
        #if os(iOS) || os(tvOS)
            guard activation == nil else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true, options: [])
            activation = .stereo
        #endif
    }

    static func release() {
        activation = nil
        grantedChannels = nil
        #if os(iOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// The width to state to LumeEngine: what the session actually outputs,
    /// never what the hardware could carry. Over-shooting the renderer fails it
    /// outright (silence, wedged pipeline), which is worse than a downmix, so
    /// `granted` is the ceiling and anything stereo or narrower resolves to
    /// `nil` — nothing worth stating, the engine's own default stands.
    static func negotiatedWidth(granted: Int, maximum: Int) -> Int? {
        let width = min(granted, maximum)
        return width > 2 ? width : nil
    }

    /// Sum of an output device's per-stream channel counts.
    static func totalChannels(inBufferCounts counts: [UInt32]) -> Int {
        counts.reduce(0) { $0 + Int($1) }
    }

    /// The macOS counterpart of `negotiatedWidth`: CoreAudio reports the device
    /// width outright, so there is nothing to negotiate — the same stereo floor
    /// applies, and the sum is never rounded up towards a nominal capability.
    static func deviceWidth(inBufferCounts counts: [UInt32]) -> Int? {
        let width = totalChannels(inBufferCounts: counts)
        return negotiatedWidth(granted: width, maximum: width)
    }

    #if os(macOS)
        /// macOS has no `AVAudioSession`, so LumeEngine falls back to a flat 2
        /// and querying CoreAudio is the host's job.
        ///
        /// No route-change observer is wired: a session opens exactly one URL
        /// with no rebuild-in-place, so a device swapped mid-playback is picked
        /// up on the next open (or `reload()`). Deliberate for this round.
        private static func defaultOutputDeviceWidth() -> Int? {
            var deviceAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var device = AudioDeviceID(0)
            var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let deviceStatus = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &deviceAddress, 0, nil, &deviceSize, &device
            )
            guard deviceStatus == noErr, device != kAudioObjectUnknown else { return nil }

            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(0)
            guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &size) == noErr, size > 0 else {
                return nil
            }
            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { storage.deallocate() }
            guard AudioObjectGetPropertyData(device, &streamAddress, 0, nil, &size, storage) == noErr else {
                return nil
            }
            let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            return deviceWidth(inBufferCounts: buffers.map(\.mNumberChannels))
        }
    #endif
}
