//
//  SubtitleSearchView+TV.swift
//  Lume
//
//  The Apple TV layout for the in-player OpenSubtitles browser.
//
//  The shared `List` layout is wrong here on two counts: it renders at iOS
//  metrics (a 13pt release name is unreadable from a sofa) and it lays out
//  flush to the display edge, inside the overscan margin a TV may crop. This
//  rebuilds the same content from the app's tvOS components — the same row
//  fills, focus treatment and section labels as the Settings panes — inside a
//  properly inset, centered column.
//

#if os(tvOS)

    import SwiftUI

    enum TVSubtitleSearchMetrics {
        /// Wide enough for a full scene-release name on one line, narrow enough
        /// that the eye doesn't have to track the whole 16:9 width.
        static let contentWidth: CGFloat = 1160
        /// Inset from the display edge. tvOS may crop up to ~5% per side on an
        /// overscanning panel, so nothing meaningful sits closer than this.
        static let horizontalInset: CGFloat = 90
        static let verticalInset: CGFloat = 60
    }

    extension SubtitleSearchView {
        var tvBody: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        header
                        if !service.isSignedIn {
                            TVOpenSubtitlesIntegrationView(isCompact: true)
                        }
                        languageRow
                        resultsBlock
                    }
                    .frame(maxWidth: TVSubtitleSearchMetrics.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, TVSubtitleSearchMetrics.horizontalInset)
                    .padding(.vertical, TVSubtitleSearchMetrics.verticalInset)
                }
                .tvSettingsBackground()
            }
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Subtitles")
                    .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                // The stream's own name — data, so verbatim.
                Text(verbatim: media.title)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }

        private var languageRow: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Languages")
                NavigationLink {
                    SubtitleLanguagePicker()
                } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "globe")
                        Text("Languages")
                        Spacer(minLength: 24)
                        Text(verbatim: languageSummary)
                            .opacity(0.7)
                            .lineLimit(1)
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 20, weight: .semibold))
                            .opacity(0.5)
                    }
                }
                .buttonStyle(TVSettingsRowButtonStyle())
            }
        }

        private var resultsBlock: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel("Results")

                switch status {
                case .searching:
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Searching…")
                    }
                    .tvSettingsSecondaryText()
                case let .failed(message):
                    Text(verbatim: message)
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                case .unsupported:
                    Text("Subtitle search is only available for movies and episodes.")
                        .tvSettingsSecondaryText()
                case .empty:
                    Text("No subtitles found for this title.")
                        .tvSettingsSecondaryText()
                case .results:
                    LazyVStack(spacing: 8) {
                        ForEach(results) { subtitle in
                            Button {
                                pick(subtitle)
                            } label: {
                                TVSubtitleResultRow(
                                    subtitle: subtitle,
                                    isDownloading: downloadingID == subtitle.id
                                )
                            }
                            .buttonStyle(TVSettingsRowButtonStyle())
                            .disabled(downloadingID != nil)
                        }
                    }
                    // Keeps the result list a single focus region, so moving up
                    // from it lands on the language row rather than skipping
                    // sideways through the rows.
                    .focusSection()

                    if let remaining = service.remainingDownloads {
                        Text("\(remaining) downloads left today.")
                            .tvSettingsSecondaryText()
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Result row

    /// One candidate, laid out for a ten-foot read: the language leads at row
    /// weight, the release name and download count trail it at reduced opacity.
    ///
    /// Opacity rather than `.secondary`: `TVSettingsRowButtonStyle` flips the
    /// whole label to black on focus, and a hierarchical style would keep the
    /// secondary lines grey against the light fill instead of following it down.
    private struct TVSubtitleResultRow: View {
        let subtitle: OnlineSubtitle
        let isDownloading: Bool

        var body: some View {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Text(verbatim: subtitle.languageName)
                            .font(.system(size: 28, weight: .semibold))
                        ForEach(subtitle.badges) { badge in
                            Image(systemName: badge.systemImage)
                                .font(.system(size: 20))
                                .opacity(0.6)
                        }
                    }
                    if !subtitle.releaseName.isEmpty {
                        Text(verbatim: subtitle.releaseName)
                            .font(.system(size: 20))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                if isDownloading {
                    ProgressView()
                } else {
                    Text("\(subtitle.downloadCount) downloads")
                        .font(.system(size: 20))
                        .opacity(0.5)
                        .layoutPriority(1)
                }
            }
        }
    }

    // MARK: - Language picker

    extension SubtitleLanguagePicker {
        var tvBody: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Languages")
                        .font(.system(size: TVSettingsMetrics.titleFontSize, weight: .bold))
                        .padding(.bottom, 18)

                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { language in
                            Button {
                                toggle(language.code)
                            } label: {
                                HStack(spacing: 16) {
                                    Text(verbatim: language.name)
                                    Spacer(minLength: 24)
                                    if service.preferredLanguages.contains(language.code) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 24, weight: .semibold))
                                    }
                                }
                            }
                            .buttonStyle(TVSettingsRowButtonStyle())
                        }
                    }
                }
                .frame(maxWidth: TVSubtitleSearchMetrics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, TVSubtitleSearchMetrics.horizontalInset)
                .padding(.vertical, TVSubtitleSearchMetrics.verticalInset)
            }
            .tvSettingsBackground()
        }
    }

#endif
