#if !os(tvOS)
    import SwiftUI

    /// Compact icon button for the toolbar — sits alongside watched/favorite icons.
    /// Shows a circular progress ring while downloading, a filled icon when complete.
    struct DownloadGlassButton: View {
        let id: String
        let downloadStatus: DownloadStatus?
        let downloads: DownloadManager
        let onStart: () -> Void
        let onDelete: () -> Void

        var body: some View {
            if let active = downloads.activeDownloads[id] {
                Button { downloads.cancelDownload(id: id) } label: {
                    progressRing(fraction: active.fractionCompleted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            } else if downloads.pendingIDs.contains(id) {
                Button { downloads.cancelDownload(id: id) } label: {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(.white)
                        .glassCircleFrame()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel download")
            } else if downloadStatus == .completed {
                Button(action: onDelete) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tint)
                        .glassCircleFrame()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove download")
            } else {
                GlassIconButton(
                    systemImage: downloadStatus == .failed ? "exclamationmark.circle" : "arrow.down.circle",
                    accessibilityLabel: downloadStatus == .failed ? "Retry download" : "Download",
                    action: onStart
                )
            }
        }

        private func progressRing(fraction: Double) -> some View {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.25), lineWidth: 2.5)
                    .frame(width: 22, height: 22)
                Circle()
                    .trim(from: 0, to: max(0.04, fraction))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Matches the manager's 250 ms progress-publish cadence
                    // so the ring sweeps continuously between updates.
                    .animation(.linear(duration: 0.25), value: fraction)
                    .frame(width: 22, height: 22)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .glassCircleFrame()
        }
    }

    private extension View {
        func glassCircleFrame() -> some View {
            frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
    }
#endif
