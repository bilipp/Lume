//
//  MultiViewScreen+Chrome.swift
//  Lume
//
//  Multi-View's floating controls: the close button and the layout picker, plus
//  the metrics and focus colours they need. Split out of `MultiViewScreen` to
//  keep that file inside the project's line-count cap.
//

import SwiftUI

extension MultiViewScreen {
    // MARK: - Chrome

    var chrome: some View {
        HStack(spacing: 12) {
            closeButton
            Spacer(minLength: 12)
            layoutPicker
        }
        .padding(.horizontal, barHorizontalPadding)
        .padding(.vertical, barVerticalPadding)
        // A scrim under the controls: they now sit over video, which can be any
        // brightness, and white-on-white is unreadable.
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        )
        #if os(tvOS)
        // Stays in the tree even while transparent, so a press up out of the
        // top tile row always has a focus target — which is what brings it
        // back into view.
        .focusSection()
        #else
        // Hidden chrome must not swallow the tap that reveals it.
        .allowsHitTesting(showsChrome)
        #endif
    }

    var barHorizontalPadding: CGFloat {
        #if os(tvOS)
            48
        #else
            12
        #endif
    }

    var barVerticalPadding: CGFloat {
        #if os(tvOS)
            32
        #else
            8
        #endif
    }

    var closeButton: some View {
        Button {
            close()
        } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.system(size: closeGlyphSize, weight: .semibold))
                .foregroundStyle(closeForeground)
                .frame(width: closeDiameter, height: closeDiameter)
                .background(closeFill, in: Circle())
        }
        .accessibilityLabel("Close Multi-View")
        #if os(tvOS)
            // Not `.plain`: on tvOS that leaves the system to paint its own white
            // focus fill *behind* the glyph, which is also white — an invisible
            // button exactly when it has focus. Own the focus colours instead.
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .focused($isCloseFocused)
            // Where `resetFocus` sends focus once the chrome is up.
            .prefersDefaultFocus(isChromeVisible, in: focusScope)
        #else
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        #endif
    }

    var closeGlyphSize: CGFloat {
        #if os(tvOS)
            22
        #else
            15
        #endif
    }

    var closeDiameter: CGFloat {
        #if os(tvOS)
            52
        #else
            36
        #endif
    }

    var closeForeground: Color {
        #if os(tvOS)
            isCloseFocused ? .black : .white
        #else
            .white
        #endif
    }

    var closeFill: Color {
        #if os(tvOS)
            isCloseFocused ? .white : .white.opacity(0.12)
        #else
            .white.opacity(0.12)
        #endif
    }

    @ViewBuilder
    var layoutPicker: some View {
        #if os(tvOS)
            HStack(spacing: 10) {
                ForEach(MultiViewLayout.allCases) { layout in
                    Button {
                        session.layout = layout
                    } label: {
                        let isActive = session.layout == layout
                        let isItemFocused = focusedLayout == layout
                        Image(systemName: layout.systemImage)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 72, height: 52)
                            .foregroundStyle(isItemFocused || isActive ? .black : .white)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(pillFill(isFocused: isItemFocused, isActive: isActive))
                            )
                    }
                    .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
                    .focused($focusedLayout, equals: layout)
                    .accessibilityLabel(Text(layout.title))
                }
            }
        #else
            Picker("Layout", selection: Binding(
                get: { session.layout },
                set: { session.layout = $0 }
            )) {
                ForEach(MultiViewLayout.allCases) { layout in
                    Image(systemName: layout.systemImage)
                        .accessibilityLabel(Text(layout.title))
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 230)
        #endif
    }

    #if os(tvOS)
        /// Focus wins over the active state: a focused pill is fully white, the
        /// active-but-unfocused one keeps a dimmer white so the current layout
        /// still reads.
        func pillFill(isFocused: Bool, isActive: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isActive { return AnyShapeStyle(.white.opacity(0.6)) }
            return AnyShapeStyle(.white.opacity(0.12))
        }
    #endif
}
