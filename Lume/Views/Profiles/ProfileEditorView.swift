import SwiftData
import SwiftUI

/// Create a new profile or edit an existing one: name, avatar symbol and tint.
/// Presented as a sheet (iOS/macOS) or full-screen cover (tvOS).
struct ProfileEditorView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss

    @Query private var allProfiles: [UserProfile]

    /// The profile being edited, or nil to create a new one.
    let profile: UserProfile?

    @State private var name: String
    @State private var symbolName: String
    @State private var color: ProfileColor
    @State private var confirmingDeletion = false

    init(profile: UserProfile? = nil) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _symbolName = State(initialValue: profile?.symbolName ?? UserProfile.defaultSymbol)
        _color = State(initialValue: profile?.color ?? .blue)
    }

    private var isEditing: Bool {
        profile != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ProfileAvatarView(symbolName: symbolName, tint: color.color, size: 96)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Name") {
                    TextField("Profile Name", text: $name)
                    #if os(iOS)
                        .textInputAutocapitalization(.words)
                    #endif
                }

                Section("Icon") {
                    symbolGrid
                }

                Section("Color") {
                    colorGrid
                }

                if isEditing, allProfiles.count > 1 {
                    Section {
                        Button(role: .destructive) {
                            confirmingDeletion = true
                        } label: {
                            Label("Delete Profile", systemImage: "trash")
                        }
                    }
                }
            }
            .platformNavigationTitle(isEditing ? "Edit Profile" : "New Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .alert("Delete Profile?", isPresented: $confirmingDeletion) {
                Button("Delete", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes this profile's watch history, progress and favorites. Your library is not affected.")
            }
            // The editor is presented as a full-screen cover on tvOS, where a
            // `Form` is transparent and would let the Settings screen show
            // through. Give it the same opaque fill as every other tvOS settings
            // surface so it reads as a self-contained screen.
            #if os(tvOS)
            .tvSettingsBackground()
            #endif
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 12)], spacing: 12) {
            ForEach(ProfileAvatar.symbols, id: \.self) { symbol in
                symbolButton(symbol)
            }
        }
        .padding(.vertical, 4)
    }

    private func symbolButton(_ symbol: String) -> some View {
        let isSelected = symbol == symbolName
        let background: Color = isSelected ? color.color : Color.secondary.opacity(0.15)
        return Button {
            symbolName = symbol
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 48)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(background, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var colorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 12)], spacing: 12) {
            ForEach(ProfileColor.allCases) { option in
                Button {
                    color = option
                } label: {
                    Circle()
                        .fill(option.color.gradient)
                        .frame(width: 40, height: 40)
                        .overlay {
                            if option == color {
                                Image(systemName: "checkmark")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(option == color ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        guard let profileManager, !trimmedName.isEmpty else { return }
        if let profile {
            profileManager.updateProfile(profile, name: trimmedName, symbolName: symbolName, color: color)
        } else {
            profileManager.createProfile(name: trimmedName, symbolName: symbolName, color: color)
        }
        dismiss()
    }

    private func delete() {
        guard let profileManager, let profile else { return }
        Task { await profileManager.deleteProfile(profile) }
        dismiss()
    }
}
