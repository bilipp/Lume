import SwiftUI

/// A circular profile avatar: the profile's SF Symbol on its tint.
struct ProfileAvatarView: View {
    let symbolName: String
    let tint: Color
    var size: CGFloat = 32

    init(symbolName: String, tint: Color, size: CGFloat = 32) {
        self.symbolName = symbolName
        self.tint = tint
        self.size = size
    }

    init(profile: UserProfile, size: CGFloat = 32) {
        symbolName = profile.symbolName
        tint = profile.tint
        self.size = size
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.48, weight: .semibold))
            // Explicit white (not accentColor, which resolves to white on tvOS
            // and would vanish on a light tint there).
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .circle)
    }
}

#Preview {
    HStack {
        ProfileAvatarView(symbolName: "person.fill", tint: .blue)
        ProfileAvatarView(symbolName: "star.fill", tint: .purple, size: 56)
        ProfileAvatarView(symbolName: "flame.fill", tint: .orange, size: 80)
    }
    .padding()
}
