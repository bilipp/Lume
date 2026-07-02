//
//  EPGProgramDetailView.swift
//  Lume
//
//  Programme detail presented when a guide cell is selected: channel, title,
//  airing time, live progress, synopsis, and a watch action that hands back to
//  the caller to start playback — live for the current programme, catch-up for
//  a past one still inside the channel's archive.
//

import SwiftUI

struct EPGProgramDetailView: View {
    let stream: LiveStream
    let cell: EPGProgramCell
    let now: Date
    let onPlay: () -> Void
    var onPlayCatchup: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private var isLive: Bool {
        cell.isLive(at: now)
    }

    private var canPlayCatchup: Bool {
        !cell.isGap && cell.isPast(at: now)
            && PlayableMedia.isCatchupAvailable(stream: stream, start: cell.start, now: now)
    }

    var body: some View {
        #if os(tvOS)
            tvBody
        #else
            standardBody
        #endif
    }

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        channelHeader

                        VStack(alignment: .leading, spacing: 8) {
                            if isLive {
                                statusBadge("On Now", color: .red)
                            } else if cell.isPast(at: now) {
                                statusBadge("Earlier", color: .secondary)
                            } else {
                                statusBadge("Upcoming", color: .accentColor)
                            }

                            Text(cell.title)
                                .font(.title2.weight(.bold))

                            timeRow

                            if isLive {
                                ProgressView(value: cell.progress(at: now))
                                    .tint(.red)
                            }
                        }

                        if !cell.detail.isEmpty {
                            Text(cell.detail)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if stream.tvArchive > 0 {
                            Label("Catch-up available for \(stream.tvArchiveDuration) days", systemImage: "clock.arrow.circlepath")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }

                        watchButton
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(stream.name)
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 360)
            #endif
        }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
        /// A roomy, 10-foot-readable detail card. No navigation chrome or Close
        /// button: tvOS dismisses a sheet with the Menu/Back button, and the toolbar
        /// "Close" rendered as an oversized, unfocusable control. Type is sized
        /// explicitly to match the rest of the tvOS UI rather than inheriting the
        /// blown-up dynamic sizes.
        private var tvBody: some View {
            HStack(alignment: .top, spacing: 56) {
                tvArtwork

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        tvStatusBadge

                        Text(cell.title)
                            .font(.system(size: 56, weight: .bold))
                            .lineLimit(3)

                        Text(stream.name)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.secondary)

                        tvTimeRow

                        if isLive {
                            ProgressView(value: cell.progress(at: now))
                                .tint(.red)
                                .frame(maxWidth: 520)
                        }

                        if stream.tvArchive > 0 {
                            Label("Catch-up available for \(stream.tvArchiveDuration) days", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 26))
                                .foregroundStyle(.blue)
                        }

                        // Keep the actions above the synopsis. The buttons are the
                        // only focusable elements here, and on tvOS the ScrollView
                        // only reveals content as focus moves. A long synopsis below
                        // them would otherwise push them off-screen and out of reach.
                        VStack(alignment: .leading, spacing: 20) {
                            if canPlayCatchup {
                                TVPlayButton(title: "Watch", systemImage: "play.fill") {
                                    onPlayCatchup()
                                    dismiss()
                                }

                                TVPlayButton(title: "Watch Live", systemImage: "dot.radiowaves.left.and.right") {
                                    onPlay()
                                    dismiss()
                                }
                            } else {
                                TVPlayButton(title: "Watch Live", systemImage: "play.fill") {
                                    onPlay()
                                    dismiss()
                                }
                            }
                        }
                        .frame(maxWidth: 460)
                        .padding(.top, 16)

                        if !cell.detail.isEmpty {
                            Text(cell.detail)
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .lineSpacing(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollClipDisabled()
            }
            .padding(80)
            .frame(width: 1280, height: 840)
        }

        private var tvArtwork: some View {
            CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: 480) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                default:
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 80))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 280, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }

        private var tvStatusBadge: some View {
            Group {
                if isLive {
                    tvBadge("On Now", color: .red)
                } else if cell.isPast(at: now) {
                    tvBadge("Earlier", color: .secondary)
                } else {
                    tvBadge("Upcoming", color: .blue)
                }
            }
        }

        private func tvBadge(_ title: LocalizedStringKey, color: Color) -> some View {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(color))
        }

        private var tvTimeRow: some View {
            HStack(spacing: 10) {
                Text(cell.start, format: .dateTime.weekday(.abbreviated).hour().minute())
                Text("–")
                Text(cell.end, format: .dateTime.hour().minute())
                Text("·")
                Text(durationText)
            }
            .font(.system(size: 28))
            .foregroundStyle(.secondary)
        }
    #endif

    private var channelHeader: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: 120) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                default:
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.fill.tertiary)
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(stream.name)
                .font(.headline)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            Text(cell.start, format: .dateTime.weekday(.abbreviated).hour().minute())
            Text("–")
            Text(cell.end, format: .dateTime.hour().minute())
            Text("·")
            Text(durationText)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var durationText: String {
        let minutes = Int(cell.end.timeIntervalSince(cell.start) / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
        }
        return "\(minutes)m"
    }

    /// The primary action: catch-up for a replayable past programme (with a
    /// secondary "Watch Live" escape hatch to the channel), live otherwise.
    @ViewBuilder
    private var watchButton: some View {
        if canPlayCatchup {
            VStack(spacing: 10) {
                Button {
                    onPlayCatchup()
                    dismiss()
                } label: {
                    Label("Watch", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onPlay()
                    dismiss()
                } label: {
                    Label("Watch Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 4)
        } else {
            Button {
                onPlay()
                dismiss()
            } label: {
                Label("Watch Live", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
    }

    private func statusBadge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
