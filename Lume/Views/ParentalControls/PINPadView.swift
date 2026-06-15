//
//  PINPadView.swift
//  Lume
//
//  A self-contained numeric PIN entry: filled/empty dots over a 3×4 keypad. It
//  uses its own buttons rather than the system keyboard, so it behaves the same
//  under tvOS focus as it does with touch and pointer. The parent owns `entry`
//  and validates it when it reaches `length`, clearing or dismissing as needed.
//

import SwiftUI

struct PINPadView: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var entry: String
    var length: Int = ParentalControls.pinLength

    #if os(tvOS)
        private let keySize: CGFloat = 90
        private let dotSize: CGFloat = 22
        private let spacing: CGFloat = 28
    #else
        private let keySize: CGFloat = 64
        private let dotSize: CGFloat = 16
        private let spacing: CGFloat = 18
    #endif

    var body: some View {
        VStack(spacing: spacing) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            dots
            keypad
        }
        .padding()
    }

    private var dots: some View {
        HStack(spacing: dotSize) {
            ForEach(0 ..< length, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.secondary, lineWidth: 2)
                    .background(Circle().fill(index < entry.count ? Color.primary : Color.clear))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(entry.count) of \(length) digits entered")
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(keySize), spacing: spacing), count: 3), spacing: spacing) {
            ForEach(1 ... 9, id: \.self) { digit in
                digitButton(digit)
            }
            Color.clear.frame(width: keySize, height: keySize)
            digitButton(0)
            deleteButton
        }
        .frame(maxWidth: keySize * 3 + spacing * 2)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            append(digit)
        } label: {
            Text("\(digit)")
                .font(.title.weight(.medium))
                .frame(width: keySize, height: keySize)
                .contentShape(Circle())
        }
        .buttonStyle(PINKeyStyle(size: keySize))
        .accessibilityLabel("\(digit)")
    }

    private var deleteButton: some View {
        Button {
            if !entry.isEmpty { entry.removeLast() }
        } label: {
            Image(systemName: "delete.left")
                .font(.title2)
                .frame(width: keySize, height: keySize)
                .contentShape(Circle())
        }
        .buttonStyle(PINKeyStyle(size: keySize))
        .disabled(entry.isEmpty)
        .accessibilityLabel("Delete")
    }

    private func append(_ digit: Int) {
        guard entry.count < length else { return }
        entry.append(String(digit))
    }
}

/// Round keypad key. Fills white on focus (tvOS) or press (touch/pointer), with
/// a quiet resting state — the same "light highlight" language as the tvOS
/// settings rows, and deliberately avoiding `Color.accentColor` (which resolves
/// to white on tvOS and would wash the key out).
private struct PINKeyStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, size: size)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        #if os(tvOS)
            @Environment(\.isFocused) private var isFocused
        #endif

        var body: some View {
            #if os(tvOS)
                let active = isFocused
            #else
                let active = configuration.isPressed
            #endif
            return configuration.label
                .foregroundStyle(active ? Color.black : Color.primary)
                .background(
                    Circle().fill(active
                        ? AnyShapeStyle(Color.white.opacity(0.95))
                        : AnyShapeStyle(Color.secondary.opacity(0.18)))
                )
                .scaleEffect(active ? 1.06 : 1)
                .opacity(isEnabled ? 1 : 0.3)
                .animation(.easeOut(duration: 0.12), value: active)
        }
    }
}

#Preview {
    @Previewable @State var entry = "12"
    return PINPadView(title: "Enter PIN", subtitle: "Enter your 4-digit PIN.", entry: $entry)
}
