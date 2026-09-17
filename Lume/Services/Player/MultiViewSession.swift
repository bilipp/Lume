//
//  MultiViewSession.swift
//  Lume
//
//  State behind Multi-View: the live channels playing at once, which tile
//  carries the audio, and how the grid is arranged. Deliberately free of any
//  view code so the grid arithmetic and slot bookkeeping are unit-testable.
//

import CoreGraphics
import Foundation

// MARK: - Layout

/// Where the spotlight layout parks the tiles that are not on stage.
enum MultiViewRailEdge {
    /// Down the trailing side. The arrangement for a wide container: height is
    /// the scarce dimension there, and a side rail lets the stage keep all of it.
    case trailing
    /// Across the bottom, for a tall container — a side rail there would squeeze
    /// the stage into a column.
    case bottom

    /// The share of the container the rail takes across its own axis. The rest,
    /// minus one gap, is the stage.
    var extentFraction: CGFloat {
        switch self {
        case .trailing: 0.26
        case .bottom: 0.27
        }
    }
}

/// How a layout places its tiles.
enum MultiViewArrangement: Equatable {
    /// Uniform rows, top to bottom, each row's tiles sharing the width.
    case grid(rows: [[Int]])
    /// One tile on stage with the rest lined up along `edge`. Slot 0 is always
    /// the stage, so promoting a tile swaps it into slot 0 rather than moving
    /// which slot the stage is.
    case spotlight(rail: [Int], edge: MultiViewRailEdge)

    /// Every slot index the arrangement places, in reading order.
    var placedIndices: [Int] {
        switch self {
        case let .grid(rows): rows.flatMap(\.self)
        case let .spotlight(rail, _): [0] + rail
        }
    }
}

/// How many tiles the Multi-View grid holds, and how they are arranged.
enum MultiViewLayout: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case four = 4
    /// One channel on stage with the other three alongside it, for when three of
    /// the four are only being kept an eye on. Its raw value carries on from the
    /// tile-count cases so the stored preference stays a single integer — it is
    /// not a tile count, which is what `slotCount` is for.
    case spotlight = 5

    var id: Int {
        rawValue
    }

    /// Tiles this layout holds.
    var slotCount: Int {
        switch self {
        case .two: 2
        case .three: 3
        case .four, .spotlight: 4
        }
    }

    var systemImage: String {
        switch self {
        case .two: "rectangle.split.2x1"
        case .three: "rectangle.split.3x1"
        case .four: "rectangle.split.2x2"
        case .spotlight: "rectangle.bottomthird.inset.filled"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .two: "2 Streams"
        case .three: "3 Streams"
        case .four: "4 Streams"
        case .spotlight: "Spotlight"
        }
    }

    /// How the tiles are placed. A tall container stacks the two- and three-tile
    /// grids vertically so each tile keeps a usable width; four tiles stay a 2×2
    /// either way, since a four-high column leaves nothing readable.
    func arrangement(isPortrait: Bool) -> MultiViewArrangement {
        switch self {
        case .two:
            .grid(rows: isPortrait ? [[0], [1]] : [[0, 1]])
        case .three:
            .grid(rows: isPortrait ? [[0], [1], [2]] : [[0, 1], [2]])
        case .four:
            .grid(rows: [[0, 1], [2, 3]])
        case .spotlight:
            .spotlight(rail: [1, 2, 3], edge: isPortrait ? .bottom : .trailing)
        }
    }

    /// Whether `index` sits in the grid's top row — the only slots with nothing
    /// above them. A press up from anywhere else has a tile to move to, so only
    /// these should summon the controls.
    func isInTopRow(_ index: Int, isPortrait: Bool) -> Bool {
        switch arrangement(isPortrait: isPortrait) {
        case let .grid(rows):
            rows.first?.contains(index) ?? false
        case let .spotlight(rail, edge):
            // The stage runs the container's full height beside a trailing rail,
            // so it is in the top row whichever edge the rail is on; the rail's
            // first tile only when the rail sits beside the stage, not under it.
            index == 0 || (edge == .trailing && index == rail.first)
        }
    }

    static let storageKey = "lume.multiView.layout"

    /// The smallest layout that holds `count` streams, so opening Multi-View
    /// with a seed never drops one on the floor.
    static func fitting(_ count: Int) -> MultiViewLayout {
        switch count {
        case ...2: .two
        case 3: .three
        default: .four
        }
    }
}

// MARK: - Geometry

extension MultiViewLayout {
    /// Frames for every tile inside a `size`-sized container, in slot order.
    ///
    /// The grid is laid out as explicit rectangles rather than nested stacks so a
    /// tile keeps its position in the view tree when the arrangement changes and
    /// only its frame moves. That is what lets a spotlight swap animate — and,
    /// far more importantly, what stops the swap from tearing a live player down
    /// and reconnecting the stream behind it.
    func frames(in size: CGSize, spacing: CGFloat) -> [CGRect] {
        let width = max(0, size.width)
        let height = max(0, size.height)
        switch arrangement(isPortrait: height > width) {
        case let .grid(rows):
            return gridFrames(rows: rows, width: width, height: height, spacing: spacing)
        case let .spotlight(rail, edge):
            return spotlightFrames(rail: rail, edge: edge, width: width, height: height, spacing: spacing)
        }
    }

    private func gridFrames(rows: [[Int]], width: CGFloat, height: CGFloat, spacing: CGFloat) -> [CGRect] {
        var frames = [CGRect](repeating: .zero, count: slotCount)
        let rowHeight = Self.split(height, into: rows.count, spacing: spacing)
        for (row, slots) in rows.enumerated() {
            let tileWidth = Self.split(width, into: slots.count, spacing: spacing)
            for (column, slot) in slots.enumerated() where frames.indices.contains(slot) {
                frames[slot] = CGRect(
                    x: (tileWidth + spacing) * CGFloat(column),
                    y: (rowHeight + spacing) * CGFloat(row),
                    width: tileWidth,
                    height: rowHeight
                )
            }
        }
        return frames
    }

    private func spotlightFrames(
        rail: [Int],
        edge: MultiViewRailEdge,
        width: CGFloat,
        height: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        var frames = [CGRect](repeating: .zero, count: slotCount)
        switch edge {
        case .trailing:
            let railWidth = max(0, width - spacing) * edge.extentFraction
            let stageWidth = max(0, width - railWidth - spacing)
            let tileHeight = Self.split(height, into: rail.count, spacing: spacing)
            frames[0] = CGRect(x: 0, y: 0, width: stageWidth, height: height)
            for (position, slot) in rail.enumerated() where frames.indices.contains(slot) {
                frames[slot] = CGRect(
                    x: stageWidth + spacing,
                    y: (tileHeight + spacing) * CGFloat(position),
                    width: railWidth,
                    height: tileHeight
                )
            }
        case .bottom:
            let railHeight = max(0, height - spacing) * edge.extentFraction
            let stageHeight = max(0, height - railHeight - spacing)
            let tileWidth = Self.split(width, into: rail.count, spacing: spacing)
            frames[0] = CGRect(x: 0, y: 0, width: width, height: stageHeight)
            for (position, slot) in rail.enumerated() where frames.indices.contains(slot) {
                frames[slot] = CGRect(
                    x: (tileWidth + spacing) * CGFloat(position),
                    y: stageHeight + spacing,
                    width: tileWidth,
                    height: railHeight
                )
            }
        }
        return frames
    }

    /// One tile's extent along an axis of `total`, once the `count - 1` gaps
    /// between the tiles have been taken out of it.
    private static func split(_ total: CGFloat, into count: Int, spacing: CGFloat) -> CGFloat {
        guard count > 0 else { return total }
        return max(0, (total - spacing * CGFloat(count - 1)) / CGFloat(count))
    }
}

// MARK: - Slot

/// One tile in the Multi-View grid. The identity is a `UUID` rather than the
/// grid position: a tile must keep its live player when a *sibling* tile is
/// filled, cleared, or dropped by a layout change, and position-based identity
/// would tear the wrong player down.
struct MultiViewSlot: Identifiable, Hashable {
    let id = UUID()
    var media: PlayableMedia?
}

// MARK: - Launch

/// One request to open Multi-View, carrying the channels it should start with.
///
/// The seed travels *with* the presentation rather than beside it: a separate
/// "is presented" flag and seed property are two independent pieces of state, and
/// the presentation can be built from the flag before the seed lands — which
/// opened the grid empty when Multi-View was started from a channel. Presenting
/// on this value instead makes that impossible, and its fresh `id` per launch
/// gives the screen a new identity so its `@State` session is rebuilt.
struct MultiViewLaunch: Identifiable {
    let id = UUID()
    var seed: [PlayableMedia] = []
}

#if os(macOS)
    /// Channels waiting for the Multi-View window to pick them up. macOS opens a
    /// single, long-lived window rather than presenting a screen, so there is no
    /// launch value to build it from — the grid takes what is queued here when it
    /// appears, and the window may already be open, in which case the channels
    /// fill its free tiles.
    @Observable
    final class MultiViewLaunchQueue {
        static let shared = MultiViewLaunchQueue()

        var pending: [PlayableMedia] = []

        private init() {}

        /// Returns the queued channels and empties the queue, so a later open
        /// from the toolbar starts blank.
        func take() -> [PlayableMedia] {
            defer { pending = [] }
            return pending
        }
    }
#endif

// MARK: - Session

/// The live Multi-View grid. Owned by `MultiViewScreen` for the lifetime of the
/// screen — nothing here is persisted beyond the chosen layout.
@Observable
final class MultiViewSession {
    /// The grid's tiles in row-major order. Always `layout.slotCount` long.
    private(set) var slots: [MultiViewSlot]

    /// The tile whose audio is heard. Every other tile plays muted: streams from
    /// different providers are never time-aligned, so more than one audible at
    /// once is just noise.
    private(set) var audioSlotID: MultiViewSlot.ID

    var layout: MultiViewLayout {
        didSet { resize() }
    }

    init(seed: [PlayableMedia] = [], layout: MultiViewLayout = .two) {
        self.layout = layout
        let initial = (0 ..< layout.slotCount).map { index in
            MultiViewSlot(media: index < seed.count ? seed[index] : nil)
        }
        slots = initial
        // Seeded or not, slot 0 exists (the smallest layout holds two tiles).
        audioSlotID = initial[0].id
    }

    /// Channels currently playing, in grid order.
    var activeMedia: [PlayableMedia] {
        slots.compactMap(\.media)
    }

    /// Channel ids on screen, so the picker can mark what is already playing.
    var usedMediaIDs: Set<String> {
        Set(activeMedia.map(\.id))
    }

    func isAudioSlot(_ slotID: MultiViewSlot.ID) -> Bool {
        slotID == audioSlotID
    }

    /// Whether the grid has a stage — one tile shown large with the rest lined up
    /// beside it. Selecting a tile means something different there: it swaps onto
    /// the stage rather than only taking the audio.
    var hasSpotlight: Bool {
        layout == .spotlight
    }

    /// Whether `slotID` is the tile on stage. Always slot 0; false outright in a
    /// uniform grid, which has no stage.
    func isStageSlot(_ slotID: MultiViewSlot.ID) -> Bool {
        hasSpotlight && slots.first?.id == slotID
    }

    /// Swap the tile at `slotID` onto the stage. The two tiles trade places, so
    /// both keep their live player: the grid is laid out by frame and a tile's
    /// identity follows its slot rather than its position, which leaves the swap
    /// a move rather than a teardown.
    ///
    /// The audio follows the stage — a spotlight grid is one channel you are
    /// watching and three you are keeping an eye on, and hearing one of the small
    /// ones over the big one is not that.
    func promote(_ slotID: MultiViewSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }), index != 0 else { return }
        slots.swapAt(0, index)
        adoptStageAudio()
    }

    /// Move the audio to `slotID`. Ignored for an empty tile: there would be
    /// nothing to hear, and the tile that *was* audible would go silent for no
    /// reason.
    func focusAudio(on slotID: MultiViewSlot.ID) {
        guard slots.first(where: { $0.id == slotID })?.media != nil else { return }
        audioSlotID = slotID
    }

    /// Put `media` in a tile — or clear it with `nil`. The tile takes the audio
    /// when nothing audible is playing, so the first channel added is always the
    /// one you hear; clearing the audible tile hands the audio to another tile
    /// that is still playing.
    func setMedia(_ media: PlayableMedia?, in slotID: MultiViewSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].media = media
        if media != nil, audioSlotMedia == nil {
            audioSlotID = slotID
        } else if media == nil, audioSlotID == slotID {
            audioSlotID = slots.first { $0.media != nil }?.id ?? slotID
        }
        adoptStageAudio()
    }

    /// Playlists already feeding a tile, ignoring `slotID` (the tile about to be
    /// changed). Providers commonly allow a single concurrent connection per
    /// account, so the picker warns before a second tile is pointed at a
    /// playlist that is already streaming.
    func playlistsInUse(excluding slotID: MultiViewSlot.ID? = nil) -> Set<UUID> {
        var inUse: Set<UUID> = []
        for slot in slots where slot.id != slotID {
            if let media = slot.media, let playlistID = Self.playlistID(of: media) {
                inUse.insert(playlistID)
            }
        }
        return inUse
    }

    /// The playlist a live stream belongs to, read from the playlist-UUID prefix
    /// `ContentSyncManager` stamps onto every synced stream id.
    static func playlistID(of media: PlayableMedia) -> UUID? {
        guard case let .live(streamID) = media.contentRef else { return nil }
        return UUID(uuidString: String(streamID.prefix(36)))
    }

    private var audioSlotMedia: PlayableMedia? {
        slots.first { $0.id == audioSlotID }?.media
    }

    /// Hands the audio to the stage whenever it has something to play, so the big
    /// tile and the sound never come apart. A no-op in a uniform grid, where the
    /// audible tile is whichever one the viewer picked.
    private func adoptStageAudio() {
        guard hasSpotlight, let stage = slots.first, stage.media != nil else { return }
        audioSlotID = stage.id
    }

    /// Grow or shrink the grid to the current layout, keeping the tiles — and so
    /// the live players — that survive. Dropping the tile that held the audio
    /// hands it to the first tile still playing.
    private func resize() {
        let target = layout.slotCount
        if slots.count < target {
            slots.append(contentsOf: (slots.count ..< target).map { _ in MultiViewSlot() })
        } else if slots.count > target {
            slots.removeLast(slots.count - target)
        }
        if !slots.contains(where: { $0.id == audioSlotID }) {
            audioSlotID = slots.first { $0.media != nil }?.id ?? slots[0].id
        }
        // Switching into the spotlight puts the audio on the stage, so arriving
        // there lines the sound up with the big tile exactly as a promotion does.
        adoptStageAudio()
    }
}
