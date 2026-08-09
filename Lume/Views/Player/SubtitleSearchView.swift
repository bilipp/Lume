//
//  SubtitleSearchView.swift
//  Lume
//
//  In-player OpenSubtitles browser: searches for subtitle tracks matching the
//  title on screen, downloads the one the viewer picks, and hands the local file
//  back for the active engine to side-load.
//
//  Presented from the engine views rather than from the controls overlay, since
//  the overlay is torn down when the controls auto-hide — a sheet anchored there
//  would vanish with it. See `subtitleSearch(isPresented:media:onPick:)`.
//
//  The search itself is shared, the layout is not: iOS/macOS get a `List`, while
//  tvOS gets a ten-foot layout built from the app's TV components (see
//  `SubtitleSearchView+TV.swift`). A `List` at iOS metrics is unreadable across a
//  room and sits flush against the overscan margin.
//

import SwiftData
import SwiftUI

/// What the results area is showing. Shared by both layouts so the two can't
/// drift on which state wins, and unit-testable without a view.
nonisolated enum SubtitleSearchStatus: Equatable {
    case searching
    case failed(String)
    /// The stream isn't something OpenSubtitles indexes (a live channel).
    case unsupported
    case empty
    case results
}

struct SubtitleSearchView: View {
    let media: PlayableMedia
    /// Handed the downloaded file; the caller loads it into its engine and the
    /// sheet dismisses itself.
    var onPick: (ExternalSubtitle) -> Void

    @Environment(\.modelContext) private var modelContext
    /// Not `private`: the tvOS layout lives in an extension in its own file.
    @Environment(\.dismiss) var dismiss

    @State var service = OpenSubtitlesService.shared
    @State var query: OpenSubtitlesQuery?
    @State var results: [OnlineSubtitle] = []
    @State var isSearching = false
    @State var errorMessage: String?
    /// The result currently being downloaded, so its row can show progress and
    /// a second tap can't spend two downloads from the daily quota.
    @State var downloadingID: String?

    var body: some View {
        Group {
            #if os(tvOS)
                tvBody
            #else
                standardBody
            #endif
        }
        .task(id: media.id) { await runSearch() }
        // Re-run when the viewer changes languages; the API filters server-side,
        // so a new selection is a new search rather than a local filter.
        .onChange(of: service.preferredLanguages) { _, _ in
            Task { await runSearch() }
        }
    }

    // MARK: - Shared state

    var status: SubtitleSearchStatus {
        if isSearching { return .searching }
        if let errorMessage { return .failed(errorMessage) }
        if query == nil { return .unsupported }
        return results.isEmpty ? .empty : .results
    }

    var languageSummary: String {
        let names = service.preferredLanguages.map { code in
            Locale.current.localizedString(forIdentifier: code)
                ?? Locale.current.localizedString(forLanguageCode: code)
                ?? code.uppercased()
        }
        return names.isEmpty ? String(localized: "Any") : names.joined(separator: ", ")
    }

    // MARK: - Actions

    func runSearch() async {
        errorMessage = nil
        results = []
        // Resolving the ids touches SwiftData on the main actor; the fetch that
        // follows is off it.
        guard let resolved = SubtitleSearchQuery.resolve(for: media.contentRef, in: modelContext) else {
            query = nil
            return
        }
        query = resolved
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await service.search(resolved)
        } catch let error as OpenSubtitlesError {
            errorMessage = String(localized: error.message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func pick(_ subtitle: OnlineSubtitle) {
        guard downloadingID == nil else { return }
        downloadingID = subtitle.id
        Task {
            defer { downloadingID = nil }
            do {
                let fileURL = try await service.download(subtitle)
                onPick(ExternalSubtitle(
                    id: subtitle.id,
                    label: "\(subtitle.languageName) · OpenSubtitles",
                    fileURL: fileURL
                ))
                dismiss()
            } catch let error as OpenSubtitlesError {
                errorMessage = String(localized: error.message)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - iOS / macOS / visionOS

    #if !os(tvOS)
        private var standardBody: some View {
            NavigationStack {
                List {
                    if !service.isSignedIn {
                        OpenSubtitlesSignInSection()
                    }
                    languageSection
                    resultsSection
                }
                .platformNavigationTitle("Subtitles")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }

        private var languageSection: some View {
            Section {
                NavigationLink {
                    SubtitleLanguagePicker()
                } label: {
                    HStack {
                        Label("Languages", systemImage: "globe")
                        Spacer()
                        Text(languageSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        private var resultsSection: some View {
            Section {
                switch status {
                case .searching:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundStyle(.secondary)
                    }
                case let .failed(message):
                    Text(message)
                        .foregroundStyle(.red)
                case .unsupported:
                    Text("Subtitle search is only available for movies and episodes.")
                        .foregroundStyle(.secondary)
                case .empty:
                    Text("No subtitles found for this title.")
                        .foregroundStyle(.secondary)
                case .results:
                    ForEach(results) { subtitle in
                        Button {
                            pick(subtitle)
                        } label: {
                            SubtitleResultRow(
                                subtitle: subtitle,
                                isDownloading: downloadingID == subtitle.id
                            )
                        }
                        // Without this the whole row inherits the tint and every
                        // line renders blue, including the release name and count.
                        .buttonStyle(.plain)
                        .disabled(downloadingID != nil)
                    }
                }
            } header: {
                Text(media.title)
            } footer: {
                if let remaining = service.remainingDownloads {
                    Text("\(remaining) downloads left today.")
                }
            }
        }
    #endif
}

// MARK: - Result row (iOS / macOS / visionOS)

#if !os(tvOS)
    private struct SubtitleResultRow: View {
        let subtitle: OnlineSubtitle
        let isDownloading: Bool

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(subtitle.languageName)
                            .font(.headline)
                        ForEach(subtitle.badges) { badge in
                            Image(systemName: badge.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !subtitle.releaseName.isEmpty {
                        Text(subtitle.releaseName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("\(subtitle.downloadCount) downloads")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isDownloading {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
        }
    }
#endif

// MARK: - Row badges

/// The at-a-glance marks on a result: hearing-impaired, uploader-trusted, and
/// machine/AI-translated. Shared by both layouts so the two agree on which
/// glyph means what.
nonisolated struct SubtitleBadge: Identifiable {
    let id: String
    let systemImage: String
}

extension OnlineSubtitle {
    var badges: [SubtitleBadge] {
        var badges: [SubtitleBadge] = []
        if isHearingImpaired { badges.append(SubtitleBadge(id: "cc", systemImage: "captions.bubble")) }
        if isFromTrusted { badges.append(SubtitleBadge(id: "trusted", systemImage: "checkmark.seal")) }
        if isMachineTranslated { badges.append(SubtitleBadge(id: "machine", systemImage: "wand.and.stars")) }
        return badges
    }
}

// MARK: - Language picker

/// Multi-select over the languages OpenSubtitles indexes. Writes straight
/// through to `OpenSubtitlesService.preferredLanguages`, which persists the
/// choice and re-runs the search.
struct SubtitleLanguagePicker: View {
    // Not `private`: the tvOS layout lives in an extension in its own file.
    @State var service = OpenSubtitlesService.shared
    @State var languages: [OpenSubtitlesLanguage] = []
    @State var searchText = ""

    var body: some View {
        Group {
            #if os(tvOS)
                tvBody
            #else
                standardBody
            #endif
        }
        .task { languages = await service.languages() }
    }

    var filtered: [OpenSubtitlesLanguage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return languages }
        return languages.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Keeps at least one language selected — an empty list would ask the API
    /// for every language there is.
    func toggle(_ code: String) {
        var selection = service.preferredLanguages
        if let index = selection.firstIndex(of: code) {
            guard selection.count > 1 else { return }
            selection.remove(at: index)
        } else {
            selection.append(code)
        }
        service.preferredLanguages = selection
    }

    #if !os(tvOS)
        private var standardBody: some View {
            List {
                ForEach(filtered) { language in
                    Button {
                        toggle(language.code)
                    } label: {
                        HStack {
                            Text(language.name)
                            Spacer()
                            if service.preferredLanguages.contains(language.code) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .platformNavigationTitle("Languages")
            .searchable(text: $searchText, prompt: Text("Search languages"))
        }
    #endif
}

// MARK: - Presentation

extension View {
    /// Presents the OpenSubtitles browser for `media`. Applied by the engine
    /// views (not their controls overlays) so the sheet outlives the controls
    /// auto-hiding underneath it.
    func subtitleSearch(
        isPresented: Binding<Bool>,
        media: PlayableMedia,
        onPick: @escaping (ExternalSubtitle) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            SubtitleSearchView(media: media, onPick: onPick)
                // The player forces dark; a sheet raised from it inherits the
                // app appearance otherwise and flashes light over the video.
                .preferredColorScheme(.dark)
        }
    }
}
