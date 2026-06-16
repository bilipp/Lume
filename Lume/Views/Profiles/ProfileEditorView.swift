import SwiftData
import SwiftUI

/// Create a new profile or edit an existing one: name, avatar symbol and tint.
/// Presented as a sheet (iOS/macOS) or full-screen cover (tvOS).
struct ProfileEditorView: View {
    @Environment(ProfileManager.self) private var profileManager: ProfileManager?
    @Environment(\.dismiss) private var dismiss

    /// The roster comes from `ProfileManager` — `UserProfile` lives in the cloud
    /// store (a separate container this view's env context doesn't bind to).
    private var allProfiles: [UserProfile] {
        profileManager?.profiles ?? []
    }

    /// The profile being edited, or nil to create a new one.
    let profile: UserProfile?

    @State private var name: String
    @State private var symbolName: String
    @State private var color: ProfileColor
    @State private var isChild: Bool
    @State private var confirmingDeletion = false

    init(profile: UserProfile? = nil) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _symbolName = State(initialValue: profile?.symbolName ?? UserProfile.defaultSymbol)
        _color = State(initialValue: profile?.color ?? .blue)
        _isChild = State(initialValue: profile?.isChild ?? false)
    }

    private var isEditing: Bool {
        profile != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Picker grid metrics. tvOS gets larger targets and generous spacing so the
    // focus zoom has room to breathe without touching its neighbours; the other
    // platforms keep the compact sheet layout.
    #if os(tvOS)
        private let symbolSize: CGFloat = 60
        private let colorSize: CGFloat = 52
        private let gridSpacing: CGFloat = 30
        private let gridVPadding: CGFloat = 22
        private let symbolFont: Font = .title2
    #else
        private let symbolSize: CGFloat = 48
        private let colorSize: CGFloat = 40
        private let gridSpacing: CGFloat = 12
        private let gridVPadding: CGFloat = 4
        private let symbolFont: Font = .title3
    #endif

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
                    // On tvOS the grouped row draws its own rounded container,
                    // which sits behind the field's native focus bezel and reads
                    // as a doubled border. Drop the row fill so only the system
                    // field treatment shows, matching `TVSettingsField`.
                    #if os(tvOS)
                    .listRowBackground(Color.clear)
                    #endif
                }

                Section("Icon") {
                    symbolGrid
                    // Match the flat treatment of the name field and avatar so
                    // the three sections read as one consistent surface on tvOS.
                    #if os(tvOS)
                    .listRowBackground(Color.clear)
                    #endif
                }

                Section("Color") {
                    colorGrid
                    #if os(tvOS)
                    .listRowBackground(Color.clear)
                    #endif
                }

                Section {
                    Toggle("Child Profile", isOn: $isChild)
                } footer: {
                    Text("Child profiles hide restricted categories from browsing and search. A parental-control PIN, if set, is required to switch away from a child profile.")
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: symbolSize + 16), spacing: gridSpacing)], spacing: gridSpacing) {
            ForEach(ProfileAvatar.symbols, id: \.self) { symbol in
                symbolButton(symbol)
            }
        }
        .padding(.vertical, gridVPadding)
    }

    private func symbolButton(_ symbol: String) -> some View {
        let isSelected = symbol == symbolName
        return Button {
            symbolName = symbol
        } label: {
            #if os(tvOS)
                // On tvOS the chip (fill + glyph colour + focus zoom) is drawn by
                // the button style so it can react to focus; the label is the bare
                // glyph.
                Image(systemName: symbol)
            #else
                Image(systemName: symbol)
                    .font(symbolFont)
                    .frame(width: symbolSize, height: symbolSize)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .background(isSelected ? color.color : Color.secondary.opacity(0.15), in: .circle)
            #endif
        }
        #if os(tvOS)
        .buttonStyle(TVSymbolPickerStyle(isSelected: isSelected, tint: color.color, diameter: symbolSize, glyphFont: symbolFont))
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var colorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: colorSize + 16), spacing: gridSpacing)], spacing: gridSpacing) {
            ForEach(ProfileColor.allCases) { option in
                Button {
                    color = option
                } label: {
                    Circle()
                        .fill(option.color.gradient)
                        .frame(width: colorSize, height: colorSize)
                        .overlay {
                            if option == color {
                                Image(systemName: "checkmark")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                }
                #if os(tvOS)
                .buttonStyle(TVColorPickerStyle(diameter: colorSize))
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(option == color ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        guard let profileManager, !trimmedName.isEmpty else { return }
        if let profile {
            profileManager.updateProfile(profile, name: trimmedName, symbolName: symbolName, color: color, isChild: isChild)
        } else {
            profileManager.createProfile(name: trimmedName, symbolName: symbolName, color: color, isChild: isChild)
        }
        dismiss()
    }

    private func delete() {
        guard let profileManager, let profile else { return }
        Task { await profileManager.deleteProfile(profile) }
        dismiss()
    }
}

#if os(tvOS)
    private let tvFocusZoom: CGFloat = 1.42
    private let tvFocusAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.72)

    /// Focus treatment for the symbol chips. The focused chip fills white with a
    /// dark glyph and zooms up — the same "light highlight on focus" language as
    /// the tvOS settings rows — while resting chips stay quiet. The grid's
    /// generous spacing keeps the enlarged chip clear of its neighbours.
    private struct TVSymbolPickerStyle: ButtonStyle {
        let isSelected: Bool
        let tint: Color
        let diameter: CGFloat
        let glyphFont: Font

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected, tint: tint, diameter: diameter, glyphFont: glyphFont)
        }

        private struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            let tint: Color
            let diameter: CGFloat
            let glyphFont: Font
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .font(glyphFont)
                    .foregroundStyle(.white)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(isFocused ? tvFocusZoom : 1)
                    .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
                    .zIndex(isFocused ? 1 : 0)
                    .animation(tvFocusAnimation, value: isFocused)
            }
        }
    }

    /// Focus treatment for the colour swatches. A swatch can't recolour to show
    /// focus, so the focused one zooms up and sits on a white disc that reads as
    /// a clean highlight halo — matching the symbol chips' white focus fill.
    private struct TVColorPickerStyle: ButtonStyle {
        let diameter: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, diameter: diameter)
        }

        private struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let diameter: CGFloat
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                configuration.label
                    .background {
                        Circle()
                            .fill(.white)
                            .frame(width: diameter + 14, height: diameter + 14)
                            .opacity(isFocused ? 1 : 0)
                    }
                    .scaleEffect(isFocused ? tvFocusZoom : 1)
                    .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 12, y: 6)
                    .zIndex(isFocused ? 1 : 0)
                    .animation(tvFocusAnimation, value: isFocused)
            }
        }
    }
#endif
