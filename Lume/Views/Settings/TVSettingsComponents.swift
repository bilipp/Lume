//
//  TVSettingsComponents.swift
//  Lume
//
//  Shared building blocks for the tvOS settings surfaces (Settings, Add
//  Playlist, Playlist detail). They give all three a single minimal, flat look
//  that mirrors the Apple TV Settings app: compact rows, small uppercase
//  section labels, and a quiet light focus highlight with no scale or shadow.
//

#if os(tvOS)

    import SwiftUI

    // MARK: - Metrics

    enum TVSettingsMetrics {
        static let rowFontSize: CGFloat = 26
        static let rowHPadding: CGFloat = 20
        static let rowVPadding: CGFloat = 14
        static let rowCornerRadius: CGFloat = 10
        static let labelFontSize: CGFloat = 18
        static let secondaryFontSize: CGFloat = 20
        static let contentMaxWidth: CGFloat = 760
        static let background = Color(white: 0.09)
    }

    extension View {
        /// The flat dark fill shared by every tvOS settings surface.
        func tvSettingsBackground() -> some View {
            background(TVSettingsMetrics.background.ignoresSafeArea())
        }
    }

    // MARK: - Section label

    /// A small uppercase grouped-section header.
    struct TVSettingsSectionLabel: View {
        private let title: String

        init(_ title: String) {
            self.title = title
        }

        var body: some View {
            Text(title.uppercased())
                .font(.system(size: TVSettingsMetrics.labelFontSize, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                .padding(.bottom, 4)
        }
    }

    // MARK: - Read-only value row

    /// A non-interactive label/value row for read-only information. Not
    /// focusable, so the focus engine skips it and moves between the actual
    /// controls — matching the Apple TV Settings information rows.
    struct TVSettingsValueRow<Value: View>: View {
        private let label: String
        private let value: Value

        init(_ label: String, @ViewBuilder value: () -> Value) {
            self.label = label
            self.value = value()
        }

        var body: some View {
            HStack(spacing: 16) {
                Text(label)
                Spacer(minLength: 16)
                value
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: TVSettingsMetrics.rowFontSize))
            .padding(.horizontal, TVSettingsMetrics.rowHPadding)
            .padding(.vertical, TVSettingsMetrics.rowVPadding + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
    }

    extension TVSettingsValueRow where Value == Text {
        init(_ label: String, value: String) {
            self.init(label) { Text(value) }
        }
    }

    // MARK: - Labelled text field

    /// A labelled input row. The field itself keeps the native tvOS appearance
    /// (its focus treatment is system-drawn and can't be cleanly replaced); only
    /// the small uppercase label and spacing are ours.
    struct TVSettingsField: View {
        let title: String
        let placeholder: String
        @Binding var text: String
        var isSecure: Bool = false
        var contentType: UITextContentType?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: TVSettingsMetrics.labelFontSize, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .font(.system(size: TVSettingsMetrics.rowFontSize))
                .textContentType(contentType)
                .autocorrectionDisabled()
            }
        }
    }

    // MARK: - Button styles

    /// A minimal sidebar category row: transparent by default, a faint fill when
    /// selected (focus elsewhere), and a quiet light highlight with dark text
    /// when focused.
    struct TVSettingsSidebarButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isSelected: isSelected)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isSelected: Bool
            @Environment(\.isFocused) private var isFocused

            var body: some View {
                let background: AnyShapeStyle = isFocused
                    ? AnyShapeStyle(Color.white.opacity(0.95))
                    : (isSelected ? AnyShapeStyle(Color.white.opacity(0.10)) : AnyShapeStyle(Color.clear))
                return configuration.label
                    .font(.system(size: TVSettingsMetrics.rowFontSize, weight: isFocused || isSelected ? .medium : .regular))
                    .foregroundStyle(isFocused ? .black : .white)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(background)
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

    /// A minimal full-width content row: a faint resting fill that turns to a
    /// quiet light highlight with dark text when focused. Flat — no scale or
    /// shadow. Pass `isDestructive` for a red treatment.
    struct TVSettingsRowButtonStyle: ButtonStyle {
        var isDestructive: Bool = false

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, isDestructive: isDestructive)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let isDestructive: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                let foreground: Color = isDestructive
                    ? (isFocused ? .white : .red)
                    : (isFocused ? .black : .white)
                let fill: AnyShapeStyle = isFocused
                    ? (isDestructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.white.opacity(0.95)))
                    : AnyShapeStyle(Color.white.opacity(0.05))
                return configuration.label
                    .font(.system(size: TVSettingsMetrics.rowFontSize))
                    .foregroundStyle(foreground)
                    .opacity(isEnabled ? 1 : 0.4)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                    .padding(.vertical, TVSettingsMetrics.rowVPadding + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(fill)
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

    /// A compact, auto-width action button (e.g. Add Playlist / Cancel). Quiet
    /// resting fill, light highlight with dark text on focus. `prominent` gives a
    /// slightly stronger resting fill for the primary action.
    struct TVSettingsActionButtonStyle: ButtonStyle {
        var prominent: Bool = false

        func makeBody(configuration: Configuration) -> some View {
            StyleBody(configuration: configuration, prominent: prominent)
        }

        struct StyleBody: View {
            let configuration: ButtonStyleConfiguration
            let prominent: Bool
            @Environment(\.isFocused) private var isFocused
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                let restFill = prominent ? Color.white.opacity(0.16) : Color.white.opacity(0.06)
                return configuration.label
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(isFocused ? .black : .white)
                    .opacity(isEnabled ? 1 : 0.4)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: TVSettingsMetrics.rowCornerRadius, style: .continuous)
                            .fill(isFocused ? AnyShapeStyle(Color.white.opacity(0.95)) : AnyShapeStyle(restFill))
                    )
                    .animation(.easeOut(duration: 0.15), value: isFocused)
            }
        }
    }

#endif
