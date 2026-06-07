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

    // MARK: - tvOS Live TV screen

    /// The unified tvOS Live TV screen for both layouts: a slim, always-visible
    /// category rail on the leading edge — topped by a single List/Guide switch —
    /// beside the content area, which shows either the channel list or the
    /// programme guide. One rail and one switch, in one place and one style,
    /// across both modes makes moving between the two views consistent.
    struct TVLiveTVScreen: View {
        let categories: [Category]
        @Binding var selectedCategory: Category?
        let displayedCategory: Category?
        @Binding var layoutModeRaw: String
        let contentSort: ContentSortOption
        let onPlay: (LiveStream) -> Void

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
        }

        var body: some View {
            HStack(spacing: 0) {
                // The rail owns its own focus state. Keeping it in a child means
                // moving focus between categories re-evaluates only the rail —
                // not this screen's `content`, which would otherwise reconstruct
                // `EPGGuideView` (and re-run its grid build) on every keypress.
                TVCategoryRail(
                    categories: categories,
                    selectedCategory: $selectedCategory,
                    layoutModeRaw: $layoutModeRaw
                )
                content
            }
        }

        @ViewBuilder
        private var content: some View {
            if let category = displayedCategory {
                switch layoutMode {
                case .guide:
                    EPGGuideView(category: category, sort: contentSort, onPlay: onPlay)
                        .id("\(category.id)-\(contentSort.rawValue)-guide")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .list:
                    TVChannelsList(category: category, sort: contentSort, onPlay: onPlay)
                        .id("\(category.id)-\(contentSort.rawValue)-list")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "tablecells",
                    description: Text("Choose a category from the list")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - tvOS category rail

    /// The leading rail: the List/Guide switch above the scrollable category
    /// list. Owns the rail's `@FocusState` so focus changes here never propagate
    /// up to `TVLiveTVScreen` and rebuild the (expensive) content area.
    private struct TVCategoryRail: View {
        let categories: [Category]
        @Binding var selectedCategory: Category?
        @Binding var layoutModeRaw: String

        /// Which rail control currently holds focus — drives the highlight.
        private enum RailItem: Hashable {
            case mode(String)
            case category(String)
        }

        @FocusState private var focused: RailItem?

        private let railWidth: CGFloat = 180

        private var layoutMode: LiveTVLayoutMode {
            LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                // The switch and the category list are each their own focus
                // section so a Down press moves between them as vertical groups.
                // Without this, pressing Down from the right-hand "Guide" segment
                // misses the left-aligned categories (only the left "List"
                // segment sits directly above them).
                viewModeSwitch
                    .padding(.horizontal, 14)
                    .padding(.top, 40)
                    .padding(.bottom, 18)
                    .focusSection()

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
                .focusSection()
            }
            .frame(width: railWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
        }

        // MARK: View-mode switch

        /// A two-segment List/Guide control rendered as a focusable pill pair —
        /// the system white-fill focus idiom reads clearly with a remote, where a
        /// `.segmented` Picker does not.
        private var viewModeSwitch: some View {
            HStack(spacing: 6) {
                ForEach(LiveTVLayoutMode.allCases) { mode in
                    modeSegment(mode)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
        }

        private func modeSegment(_ mode: LiveTVLayoutMode) -> some View {
            let isActive = layoutMode == mode
            let isItemFocused = focused == .mode(mode.rawValue)
            return Button {
                layoutModeRaw = mode.rawValue
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                    Text(mode.label)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(segmentForeground(isFocused: isItemFocused, isActive: isActive))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(segmentFill(isFocused: isItemFocused, isActive: isActive))
                )
            }
            .buttonStyle(TVCardButtonStyle(focusScale: 1.04))
            .focused($focused, equals: .mode(mode.rawValue))
            .animation(.easeOut(duration: 0.18), value: isItemFocused)
        }

        private func segmentForeground(isFocused: Bool, isActive: Bool) -> Color {
            if isFocused { return .black }
            if isActive { return .white }
            return .white.opacity(0.5)
        }

        private func segmentFill(isFocused: Bool, isActive: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isActive { return AnyShapeStyle(.white.opacity(0.22)) }
            return AnyShapeStyle(.clear)
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
