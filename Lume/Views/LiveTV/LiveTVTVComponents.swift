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

    // MARK: - tvOS EPG Guide screen

    /// The Live TV "Guide" experience on tvOS: a wide programme grid with a slim,
    /// always-visible category rail pinned to the leading edge. The rail is
    /// selectable in place — focusing an entry highlights it (system white-fill
    /// idiom) and clicking switches the grid's category — so the guide keeps its
    /// space while a category change stays one press to the left.
    struct TVEPGScreen: View {
        let categories: [Category]
        @Binding var selectedCategory: Category?
        let displayedCategory: Category?
        @Binding var layoutModeRaw: String
        let contentSort: ContentSortOption
        let onPlay: (LiveStream) -> Void

        /// Which rail control currently holds focus — drives the highlight.
        private enum RailItem: Hashable {
            case modeToggle
            case category(String)
        }

        @FocusState private var focused: RailItem?

        private let railWidth: CGFloat = 170

        var body: some View {
            HStack(spacing: 0) {
                rail
                grid
            }
        }

        @ViewBuilder
        private var grid: some View {
            if let category = displayedCategory {
                EPGGuideView(category: category, sort: contentSort, onPlay: onPlay)
                    .id("\(category.id)-\(contentSort.rawValue)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "tablecells",
                    description: Text("Choose a category from the list")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        // MARK: Rail

        private var rail: some View {
            VStack(alignment: .leading, spacing: 0) {
                modeToggle
                    .padding(.horizontal, 14)
                    .padding(.top, 40)
                    .padding(.bottom, 18)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(categories) { category in
                            categoryButton(category)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled()
            }
            .frame(width: railWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .focusSection()
        }

        /// Switches back to the List layout. The reverse switch lives in the
        /// List layout's segmented toggle, so the two modes stay reachable.
        private var modeToggle: some View {
            Button {
                layoutModeRaw = LiveTVLayoutMode.list.rawValue
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20, weight: .semibold))
                    Text("List")
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(focused == .modeToggle ? .black : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(focused == .modeToggle
                            ? AnyShapeStyle(.white)
                            : AnyShapeStyle(.white.opacity(0.12)))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($focused, equals: .modeToggle)
        }

        private func categoryButton(_ category: Category) -> some View {
            let isSelected = selectedCategory?.id == category.id
            let isItemFocused = focused == .category(category.id)
            return Button {
                selectedCategory = category
            } label: {
                Text(category.name)
                    .font(.system(
                        size: 22,
                        weight: isSelected || isItemFocused ? .semibold : .regular
                    ))
                    .foregroundStyle(textColor(isFocused: isItemFocused, isSelected: isSelected))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(categoryFill(isFocused: isItemFocused, isSelected: isSelected))
                    )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.03))
            .focused($focused, equals: .category(category.id))
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private func textColor(isFocused: Bool, isSelected: Bool) -> Color {
            if isFocused { return .black }
            if isSelected { return .white }
            return .white.opacity(0.6)
        }

        private func categoryFill(isFocused: Bool, isSelected: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isSelected { return AnyShapeStyle(.white.opacity(0.14)) }
            return AnyShapeStyle(.clear)
        }
    }
#endif
