//
//  KSSubtitleOverlay.swift
//  Lume
//
//  Renders the KSPlayer engine's subtitle parts on top of the video.
//
//  Lume hosts the bare `KSVideoPlayer` representable, which draws only the video
//  surface. KSPlayer's own subtitle rendering lives in its full `KSVideoPlayerView`
//  wrapper (an internal `VideoSubtitleView`) that Lume does not use — so although
//  the coordinator decodes and time-syncs the selected track into
//  `subtitleModel.parts`, nothing ever drew them and subtitles never appeared.
//  This view draws those parts, mirroring KSPlayer's `VideoSubtitleView` layout.
//

import KSPlayer
import SwiftUI

/// Which content a subtitle cue renders as. Bitmap cues (PGS / VobSub) take
/// precedence over text, matching KSPlayer's own `SubtitlePart` layout; a cue
/// carrying neither renders nothing. Extracted from the view body so the
/// decision that fixed the subtitles-never-appear bug — a text cue must map to a
/// render path rather than be silently dropped — is unit-testable without a
/// running player.
enum KSSubtitleCue: Equatable {
    case image
    case text
    case empty

    init(hasImage: Bool, hasText: Bool) {
        if hasImage {
            self = .image
        } else if hasText {
            self = .text
        } else {
            self = .empty
        }
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
struct KSSubtitleOverlay: View {
    @ObservedObject var subtitleModel: SubtitleModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ZStack {
                ForEach(subtitleModel.parts) { part in
                    KSSubtitlePartView(part: part)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
        // The subtitle layer must never intercept taps meant for the video /
        // controls beneath it.
        .allowsHitTesting(false)
    }
}

/// A single subtitle cue — a bitmap (PGS / VobSub) or styled text (SRT / WebVTT
/// / mov_text) — laid out at the position the cue requests, falling back to the
/// player-wide default. Mirrors KSPlayer's private `SubtitlePart.subtitleView`.
@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
private struct KSSubtitlePartView: View {
    let part: SubtitlePart

    var body: some View {
        VStack {
            switch KSSubtitleCue(hasImage: part.image != nil, hasText: part.text != nil) {
            case .image:
                if let image = part.image { imageCue(image) }
            case .text:
                if let text = part.text { textCue(text) }
            case .empty:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func imageCue(_ image: UIImage) -> some View {
        Spacer()
        GeometryReader { geometry in
            let fitRect = image.fitRect(geometry.size)
            Image(uiImage: image)
                .resizable()
                .offset(CGSize(width: fitRect.origin.x, height: fitRect.origin.y))
                .frame(width: fitRect.size.width, height: fitRect.size.height)
        }
        .padding()
    }

    @ViewBuilder
    private func textCue(_ text: NSAttributedString) -> some View {
        let position = part.textPosition ?? SubtitleModel.textPosition
        if position.verticalAlign == .bottom || position.verticalAlign == .center {
            Spacer()
        }
        Text(AttributedString(text))
            .font(Font(SubtitleModel.textFont))
            .shadow(color: .black.opacity(0.9), radius: 1, x: 1, y: 1)
            .foregroundStyle(SubtitleModel.textColor)
            .italic(SubtitleModel.textItalic)
            .background(SubtitleModel.textBackgroundColor)
            .multilineTextAlignment(.center)
            .alignmentGuide(position.horizontalAlign) { $0[.leading] }
            .padding(position.edgeInsets)
        if position.verticalAlign == .top || position.verticalAlign == .center {
            Spacer()
        }
    }
}
