//
//  PlaybackLiveActivity.swift
//  LumeWidgets
//
//  Lock-screen banner + Dynamic Island for the active playback session.
//  Everything renders from the content state pushed by the app's
//  `NowPlayingService`; tapping any surface deep-links back into playback.
//

import ActivityKit
import SwiftUI
import WidgetKit

struct PlaybackLiveActivity: Widget {
    private static let resumeURL = URL(string: "lume://resume")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlaybackActivityAttributes.self) { context in
            PlaybackLockScreenView(state: context.state)
                .widgetURL(Self.resumeURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlaybackArtworkView(fileName: context.state.artworkFileName, size: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isLive {
                        LiveBadge()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: context.state.isPaused ? "pause.fill" : "play.fill")
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        if let secondary = context.state.programmeTitle ?? context.state.subtitle {
                            Text(secondary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        PlaybackProgressView(state: context.state)
                        PlaybackUpNextView(state: context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PlaybackArtworkView(fileName: context.state.artworkFileName, size: 23)
            } compactTrailing: {
                if context.state.isPaused {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.secondary)
                } else if context.state.isLive {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.red)
                } else if let start = context.state.windowStart, let end = context.state.windowEnd, start < end {
                    ProgressView(timerInterval: start ... end, countsDown: false) {} currentValueLabel: {}
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "play.fill")
                    .foregroundStyle(context.state.isLive ? .red : .white)
            }
            .widgetURL(Self.resumeURL)
        }
    }
}

/// The lock-screen / banner presentation.
private struct PlaybackLockScreenView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            PlaybackArtworkView(fileName: state.artworkFileName, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if state.isLive {
                        LiveBadge()
                    } else if state.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let secondary = state.programmeTitle ?? state.subtitle {
                    Text(secondary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                PlaybackProgressView(state: state)
                PlaybackUpNextView(state: state)
            }
        }
        .padding(14)
        .activityBackgroundTint(Color.black.opacity(0.55))
        .activitySystemActionForegroundColor(.white)
    }
}

/// Progress for the current programme (live) or the stream position (VOD).
/// While playing it ticks on its own via the timer interval; while paused it
/// freezes at the last reported position.
private struct PlaybackProgressView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if state.isPaused, let elapsed = state.elapsed, let duration = state.duration, duration > 0 {
            ProgressView(value: min(elapsed / duration, 1))
                .progressViewStyle(.linear)
                .tint(.white)
        } else if let start = state.windowStart, let end = state.windowEnd, start < end {
            HStack(spacing: 8) {
                if state.isLive {
                    Text(start, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(timerInterval: start ... end, countsDown: false) {} currentValueLabel: {}
                    .progressViewStyle(.linear)
                    .tint(.white)
                if state.isLive {
                    Text(end, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// The EPG "up next" line (live TV only).
private struct PlaybackUpNextView: View {
    let state: PlaybackActivityAttributes.ContentState

    var body: some View {
        if let nextTitle = state.nextTitle, let nextStart = state.nextStart {
            Text("\(nextStart, style: .time) · \(nextTitle)", comment: "Live Activity up-next line: start time · programme title")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE", comment: "Badge marking a live TV stream")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.red, in: Capsule())
    }
}

/// Channel logo / poster from the app-group container, with a placeholder when
/// no artwork could be written. Widget extensions can't load network images,
/// so the file the app dropped in the shared container is the only source.
private struct PlaybackArtworkView: View {
    let fileName: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let fileName,
               let url = PlaybackActivityArtworkStore.url(for: fileName),
               let image = UIImage(contentsOfFile: url.path)
            {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.1))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
