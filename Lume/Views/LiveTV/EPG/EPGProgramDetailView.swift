//
//  EPGProgramDetailView.swift
//  Lume
//
//  Programme detail presented when a guide cell is selected: channel, title,
//  airing time, live progress, synopsis, and a "Watch Live" action that hands
//  back to the caller to start playback.
//

import SwiftUI

struct EPGProgramDetailView: View {
    let stream: LiveStream
    let cell: EPGProgramCell
    let now: Date
    let onPlay: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var isLive: Bool {
        cell.isLive(at: now)
    }

    var body: some View {
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

    private var watchButton: some View {
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

    private func statusBadge(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
