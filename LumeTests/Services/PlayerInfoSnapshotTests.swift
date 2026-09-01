import Foundation
@testable import Lume
import Testing

/// The caption's exact English wording is only asserted on an English host: the
/// `" fps"` unit and the decimal separator are both localized, so the literal
/// strings below are only the expected rendering under English.
private nonisolated func isEnglishHost() -> Bool {
    Locale.preferredLanguages.first?.hasPrefix("en") ?? false
}

private let captionSeparator = "  ·  "

private func makeMedia(
    contentRef: PlayableMedia.ContentRef,
    kind: PlayableMedia.Kind,
    subtitle: String? = nil
) -> PlayableMedia {
    PlayableMedia(
        id: "media-1",
        url: URL(string: "http://example.com/stream.ts")!,
        title: "Title",
        subtitle: subtitle,
        posterURL: nil,
        kind: kind,
        startTime: 0,
        contentRef: contentRef
    )
}

private let liveMedia = makeMedia(contentRef: .live("l-1"), kind: .live)
private let movieMedia = makeMedia(contentRef: .movie("m-1"), kind: .vod)
private let episodeMedia = makeMedia(contentRef: .episode("e-1"), kind: .vod, subtitle: "Breaking Bad")

private let fullDetails = StreamInfoDetails(
    playlistName: "Provider A",
    categoryName: "Sports",
    epg: ChannelEPG(
        current: EPGSlot(title: "Match of the Day", start: .distantPast, end: .distantFuture),
        next: nil
    )
)

private let uhdVideoInfo = PlayerVideoInfo(width: 3840, height: 2160, fps: 24, codec: "hevc")

/// AVPlayer's real-world shape: dimensions only, never a codec or a frame rate.
/// `FullScreenPlayerView.isAirPlayOverride` forces this engine during a cast, so
/// it is not an edge case.
private let avPlayerVideoInfo = PlayerVideoInfo(width: 1920, height: 1080, fps: 0, codec: nil)

struct PlayerInfoSnapshotTests {
    // MARK: - Detail levels

    @Test func `simple omits the technical readout and the engine`() {
        let snapshot = PlayerInfoSnapshot(
            media: liveMedia,
            details: fullDetails,
            videoInfo: uhdVideoInfo,
            engine: .ksPlayer,
            detailLevel: .simple
        )

        #expect(snapshot.captionParts == ["Match of the Day", "Provider A", "Sports"])
        #expect(snapshot.techCaption.isEmpty)
    }

    @Test(.enabled(if: isEnglishHost()))
    func `advanced adds quality codec frame rate and engine`() {
        let snapshot = PlayerInfoSnapshot(
            media: liveMedia,
            details: fullDetails,
            videoInfo: uhdVideoInfo,
            engine: .ksPlayer,
            detailLevel: .advanced
        )

        #expect(snapshot.captionParts == [
            "Match of the Day", "Provider A", "Sports", "4K", "HEVC", "24 fps", "KSPlayer"
        ])
        #expect(snapshot.techCaption == "4K  ·  HEVC  ·  24 fps")
    }

    @Test func `playlist name is present at both detail levels`() {
        for level in StreamInfoDetailLevel.allCases {
            let snapshot = PlayerInfoSnapshot(
                media: liveMedia,
                details: fullDetails,
                videoInfo: uhdVideoInfo,
                engine: .ksPlayer,
                detailLevel: level
            )
            #expect(snapshot.captionParts.contains("Provider A"))
        }
    }

    @Test func `advanced without an engine omits the engine part`() {
        let snapshot = PlayerInfoSnapshot(
            media: liveMedia,
            details: fullDetails,
            videoInfo: nil,
            engine: nil,
            detailLevel: .advanced
        )

        #expect(snapshot.captionParts == ["Match of the Day", "Provider A", "Sports"])
    }

    // MARK: - Collapsing

    @Test func `AVPlayer video info yields no zero frame rate element`() {
        let snapshot = PlayerInfoSnapshot(
            media: movieMedia,
            details: StreamInfoDetails(
                playlistName: "Provider A",
                categoryName: nil,
                epg: nil
            ),
            videoInfo: avPlayerVideoInfo,
            engine: .avPlayer,
            detailLevel: .advanced
        )

        let parts = snapshot.captionParts
        #expect(parts == ["Provider A", "1080p", "AVPlayer"])
        #expect(!parts.contains { $0.isEmpty })
        #expect(!parts.contains { $0.contains("fps") })

        let joined = parts.joined(separator: captionSeparator)
        #expect(joined == "Provider A  ·  1080p  ·  AVPlayer")
        #expect(!joined.contains("·  ·"))
        #expect(!joined.hasPrefix("·"))
        #expect(!joined.hasSuffix("·"))
    }

    @Test func `live channel without EPG collapses without a leading separator`() {
        let snapshot = PlayerInfoSnapshot(
            media: liveMedia,
            details: StreamInfoDetails(
                playlistName: "Provider A",
                categoryName: "Sports",
                epg: nil
            ),
            videoInfo: nil,
            engine: .ksPlayer,
            detailLevel: .simple
        )

        let parts = snapshot.captionParts
        #expect(parts == ["Provider A", "Sports"])
        #expect(!parts.contains { $0.isEmpty })

        let joined = parts.joined(separator: captionSeparator)
        #expect(joined == "Provider A  ·  Sports")
        #expect(!joined.hasPrefix(" "))
        #expect(!joined.hasPrefix("·"))
    }

    @Test func `no details at all yields no parts`() {
        let snapshot = PlayerInfoSnapshot(
            media: liveMedia,
            details: nil,
            videoInfo: nil,
            engine: nil,
            detailLevel: .advanced
        )

        #expect(snapshot.captionParts.isEmpty)
        #expect(snapshot.techCaption.isEmpty)
        #expect(snapshot.topCaption == nil)
    }

    // MARK: - Top caption

    @Test func `top caption is the EPG now title for live`() {
        let snapshot = PlayerInfoSnapshot(
            media: liveMedia,
            details: fullDetails,
            videoInfo: nil,
            engine: nil,
            detailLevel: .simple
        )
        #expect(snapshot.topCaption == "Match of the Day")
    }

    @Test func `top caption is the series name for an episode`() {
        let snapshot = PlayerInfoSnapshot(
            media: episodeMedia,
            details: nil,
            videoInfo: nil,
            engine: nil,
            detailLevel: .simple
        )
        #expect(snapshot.topCaption == "Breaking Bad")
    }

    @Test func `top caption is nil for a movie`() {
        let snapshot = PlayerInfoSnapshot(
            media: movieMedia,
            details: nil,
            videoInfo: nil,
            engine: nil,
            detailLevel: .simple
        )
        #expect(snapshot.topCaption == nil)
    }

    // MARK: - Info badges

    @Test func `info badges carry the quality tag and uppercased codec`() {
        let snapshot = PlayerInfoSnapshot(
            media: movieMedia,
            details: nil,
            videoInfo: uhdVideoInfo,
            engine: nil,
            detailLevel: .simple
        )
        #expect(snapshot.infoBadges == ["4K", "HEVC"])
    }

    @Test func `info badges are empty without video info`() {
        let snapshot = PlayerInfoSnapshot(
            media: movieMedia,
            details: nil,
            videoInfo: nil,
            engine: nil,
            detailLevel: .advanced
        )
        #expect(snapshot.infoBadges.isEmpty)
    }
}

struct PlayerVideoInfoCaptionTests {
    @Test(.enabled(if: isEnglishHost()))
    func `integral frame rate renders without decimals`() {
        let info = PlayerVideoInfo(width: 1920, height: 1080, fps: 24, codec: "h264")
        #expect(info.captionParts == ["1080p", "H264", "24 fps"])
    }

    /// The unit is English-gated; the number is not, because the format style
    /// is deliberately locale-aware — a host with an English app language can
    /// still sit in a comma-separator region.
    @Test(.enabled(if: isEnglishHost()))
    func `fractional frame rate renders to two places`() {
        let info = PlayerVideoInfo(width: 1920, height: 1080, fps: 23.976, codec: "h264")
        let separator = Locale.current.decimalSeparator ?? "."
        #expect(info.captionParts == ["1080p", "H264", "23\(separator)98 fps"])
    }

    @Test func `frame rate uses the locale decimal separator`() {
        let info = PlayerVideoInfo(width: 1920, height: 1080, fps: 23.976, codec: nil)
        let separator = Locale.current.decimalSeparator ?? "."
        #expect(info.captionParts.contains { $0.contains("23\(separator)98") })
    }

    @Test func `zero frame rate contributes no part`() {
        let info = PlayerVideoInfo(width: 1920, height: 1080, fps: 0, codec: nil)
        #expect(info.captionParts == ["1080p"])
    }

    @Test(.enabled(if: isEnglishHost()))
    func `spoken parts spell out the frame rate`() {
        let info = PlayerVideoInfo(width: 3840, height: 2160, fps: 24, codec: "hevc")
        #expect(info.spokenCaptionParts == ["4K", "HEVC", "24 frames per second"])
    }
}
