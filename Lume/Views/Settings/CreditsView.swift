//
//  CreditsView.swift
//  Lume
//
//  The Settings → About → Acknowledgements screen (iOS / macOS). Lists Lume's
//  own licence, the open-source playback engines it bundles, and the metadata
//  providers whose terms require attribution. Links are tappable here; the tvOS
//  equivalent lives in `tvCreditsSection` (Apple TV can't open a URL), and both
//  read their verbatim names / URLs from `CreditsInfo` so they can't drift.
//

#if !os(tvOS)

    import SwiftUI

    struct CreditsView: View {
        var body: some View {
            List {
                lumeSection
                librariesSection
                metadataSection
            }
            .platformNavigationTitle("Acknowledgements")
        }

        private var lumeSection: some View {
            Section {
                if let url = CreditsInfo.sourceCodeURL {
                    Link(destination: url) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                if let url = CreditsInfo.licenseURL {
                    Link(destination: url) {
                        HStack {
                            Label("License", systemImage: "doc.text")
                            Spacer()
                            Text(verbatim: CreditsInfo.licenseName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Lume")
            } footer: {
                Text("Lume is free, open-source software, licensed under the GNU Affero General Public License v3.")
            }
        }

        private var librariesSection: some View {
            Section {
                ForEach(CreditsInfo.libraries) { library in
                    LibraryRow(library: library)
                }
            } header: {
                Text("Open Source")
            } footer: {
                Text("Lume's playback engines build on these open-source projects. Each remains under its own license.")
            }
        }

        private var metadataSection: some View {
            Section {
                if let url = CreditsInfo.tmdbURL {
                    Link(destination: url) {
                        Label("The Movie Database (TMDB)", systemImage: "film")
                    }
                }
                if let url = CreditsInfo.omdbURL {
                    Link(destination: url) {
                        Label("OMDb API", systemImage: "star")
                    }
                }
                if let url = CreditsInfo.traktURL {
                    Link(destination: url) {
                        Label("Trakt", systemImage: "rectangle.stack.badge.play")
                    }
                }
            } header: {
                Text("Metadata")
            } footer: {
                Text("Artwork, ratings and details are provided by these services. This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }
        }
    }

    /// A single dependency row: product name, its licence, and a tappable link to
    /// the project's home page.
    private struct LibraryRow: View {
        let library: CreditsInfo.Library

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: library.name)
                    Spacer()
                    Text(verbatim: library.license)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let url = library.url {
                    Link(destination: url) {
                        Text(verbatim: library.displayURL)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    #Preview {
        NavigationStack {
            CreditsView()
        }
    }

#endif
