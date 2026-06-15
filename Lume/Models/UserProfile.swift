import Foundation
import SwiftData
import SwiftUI

/// A user profile: a named identity with its own watch history, progress and
/// favorites. The catalog models hold the *active* profile's state (see
/// `ProfileManager`); each profile's full saved state lives in its own set of
/// `UserContentState` records, keyed by `profileID`.
///
/// Lives in the CloudKit-synced "CloudUserData" store, so the profile roster
/// appears on every device sharing the Apple ID. CloudKit constraints honoured:
/// all stored properties defaulted, no `@Attribute(.unique)`, no relationships.
@Model
final class UserProfile {
    var id: UUID = UUID()
    var name: String = ""
    /// SF Symbol name used as the avatar.
    var symbolName: String = UserProfile.defaultSymbol
    /// Palette key (see `ProfileColor`) for the avatar tint.
    var colorRaw: String = ProfileColor.blue.rawValue
    var createdAt: Date = Date()
    /// User-facing ordering in the switcher.
    var sortOrder: Int = 0
    var updatedAt: Date = Date()
    /// A child profile: restricted categories (and their content) are hidden, and
    /// leaving it for a non-child profile requires the parental-control PIN.
    var isChild: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = UserProfile.defaultSymbol,
        colorRaw: String = ProfileColor.blue.rawValue,
        sortOrder: Int = 0,
        isChild: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorRaw = colorRaw
        self.sortOrder = sortOrder
        self.isChild = isChild
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension UserProfile {
    /// The first profile every install starts with. A fixed id (not a random
    /// one) so two devices bootstrapping independently converge on *the same*
    /// default profile instead of creating two — `ProfileManager` de-duplicates
    /// by id, keeping the earliest, should both ever reach CloudKit.
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-0000DEFA0117")!

    static let defaultSymbol = "person.crop.circle.fill"

    var color: ProfileColor {
        ProfileColor(rawValue: colorRaw) ?? .blue
    }

    var tint: Color {
        color.color
    }
}

/// Curated avatar tints. Stored by raw key so the value round-trips through
/// CloudKit and stays stable regardless of system color changes.
enum ProfileColor: String, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, brown

    var id: String {
        rawValue
    }

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .indigo: .indigo
        case .brown: .brown
        }
    }
}

/// Curated SF Symbols offered as avatars in the profile editor.
enum ProfileAvatar {
    static let symbols = [
        "person.crop.circle.fill",
        "person.fill",
        "face.smiling.fill",
        "star.fill",
        "heart.fill",
        "bolt.fill",
        "flame.fill",
        "leaf.fill",
        "pawprint.fill",
        "gamecontroller.fill",
        "music.note",
        "film.fill",
        "tv.fill",
        "sportscourt.fill",
        "globe",
        "moon.stars.fill",
        "crown.fill",
        "graduationcap.fill"
    ]
}
