//
//  LiveTVTVComponents.swift
//  Lume
//
//  tvOS-only Live TV browsing components: the wide category rail and the large,
//  focusable channel list with inline now/next EPG. Split out from LiveTVView
//  to keep that file focused on cross-platform composition.
//

#if os(tvOS)
    import SwiftData
    import SwiftUI

    // MARK: - tvOS Category Sidebar

    struct TVCategorySidebar: View {
        let categories: [Category]
        @Binding var selectedCategory: Category?

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(categories) { category in
                        TVCategoryRow(
                            category: category,
                            isSelected: selectedCategory?.id == category.id
                        ) {
                            selectedCategory = category
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 40)
            }
            .focusSection()
        }
    }

    private struct TVCategoryRow: View {
        let category: Category
        let isSelected: Bool
        let action: () -> Void

        @FocusState private var isFocused: Bool

        var body: some View {
            Button(action: action) {
                Text(category.name)
                    .font(.system(size: 30, weight: isSelected || isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused || isSelected ? .white : .white.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(background)
                    )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($isFocused)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        private var background: AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white.opacity(0.22)) }
            if isSelected { return AnyShapeStyle(.white.opacity(0.1)) }
            return AnyShapeStyle(.clear)
        }
    }

    // MARK: - tvOS Channels List

    struct TVChannelsList: View {
        let category: Category
        let onPlay: (LiveStream) -> Void
        @Query private var streams: [LiveStream]

        init(category: Category, sort: ContentSortOption, onPlay: @escaping (LiveStream) -> Void) {
            self.category = category
            self.onPlay = onPlay
            let categoryId = category.id
            _streams = Query(
                filter: #Predicate<LiveStream> { $0.categoryId == categoryId && $0.isHidden == false },
                sort: sort.liveStreamDescriptors
            )
        }

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if streams.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                        .padding(.top, 80)
                    } else {
                        ForEach(streams) { stream in
                            TVChannelRow(stream: stream) {
                                onPlay(stream)
                            }
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 40)
            }
            .focusSection()
        }
    }

    private struct TVChannelRow: View {
        let stream: LiveStream
        let onPlay: () -> Void

        @Query private var epgListings: [EPGListing]
        @FocusState private var isFocused: Bool

        init(stream: LiveStream, onPlay: @escaping () -> Void) {
            self.stream = stream
            self.onPlay = onPlay
            let channelId = stream.epgChannelId ?? ""
            let now = Date()
            _epgListings = Query(
                filter: #Predicate<EPGListing> { $0.channelId == channelId && $0.end > now },
                sort: [SortDescriptor(\.start)]
            )
        }

        private var now: Date {
            Date()
        }

        private var currentEPG: EPGListing? {
            epgListings.first { $0.start <= now && now < $0.end }
        }

        private var nextEPG: EPGListing? {
            epgListings.filter { $0.start > now }.min { $0.start < $1.start }
        }

        var body: some View {
            Button(action: onPlay) {
                HStack(spacing: 24) {
                    logo

                    VStack(alignment: .leading, spacing: 6) {
                        Text(stream.name)
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)

                        if let current = currentEPG {
                            Text(current.title)
                                .font(.system(size: 25))
                                .foregroundStyle(secondaryColor)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                Text(current.start, style: .time)
                                Text("–")
                                Text(current.end, style: .time)
                            }
                            .font(.system(size: 22))
                            .foregroundStyle(tertiaryColor)

                            if let next = nextEPG {
                                HStack(spacing: 6) {
                                    Text("Next:")
                                    Text(next.title).lineLimit(1)
                                    Text(next.start, style: .time)
                                }
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                            }
                        } else if stream.epgChannelId != nil {
                            Text("No EPG data")
                                .font(.system(size: 22))
                                .foregroundStyle(tertiaryColor)
                        } else {
                            Text("Live")
                                .font(.system(size: 22))
                                .foregroundStyle(secondaryColor)
                        }

                        if stream.tvArchive > 0 {
                            Label("Catchup: \(stream.tvArchiveDuration)d", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.blue)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(tertiaryColor)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isFocused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.white.opacity(0.06)))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($isFocused)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        }

        private var logo: some View {
            CachedAsyncImage(url: URL(string: stream.streamIcon ?? ""), maxPixelSize: 84) { phase in
                switch phase {
                case .empty:
                    Rectangle().fill(Color.white.opacity(0.12)).overlay { ProgressView() }
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fit)
                case .failure:
                    Rectangle().fill(Color.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(secondaryColor)
                        }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }

        private var primaryColor: Color {
            .white
        }

        private var secondaryColor: Color {
            .white.opacity(0.7)
        }

        private var tertiaryColor: Color {
            .white.opacity(0.45)
        }
    }
#endif
