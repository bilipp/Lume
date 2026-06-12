#if !os(tvOS)
    import SwiftUI

    /// Full-width secondary button below the Play button showing download state.
    struct DownloadButton: View {
        let id: String
        let downloadStatus: DownloadStatus?
        let downloads: DownloadManager
        let onStart: () -> Void
        let onDelete: () -> Void

        var body: some View {
            if let active = downloads.activeDownloads[id] {
                HStack(spacing: 12) {
                    if active.fractionCompleted > 0 {
                        ProgressView(value: active.fractionCompleted)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .frame(maxWidth: .infinity)
                    }
                    Button {
                        downloads.cancelDownload(id: id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)
            } else if downloads.pendingIDs.contains(id) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        downloads.cancelDownload(id: id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)
            } else if downloadStatus == .completed {
                Button(role: .destructive, action: onDelete) {
                    Label("Remove Download", systemImage: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
            } else if downloadStatus == .failed {
                Button(action: onStart) {
                    Label("Retry Download", systemImage: "arrow.clockwise.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button(action: onStart) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }
#endif
