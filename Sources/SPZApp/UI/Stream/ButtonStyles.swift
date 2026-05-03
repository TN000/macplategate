import SwiftUI

/// Custom ButtonStyle balík sdílený mezi Stream / Settings / Sheets views.
///
/// Extracted ze `StreamView.swift` do samostatného souboru jako součást
/// big-refactor split (krok #10 audit roadmap). Stylové komponenty žádný state,
/// žádné dependencies — bezpečné pro file-level extract.

struct ToggleButtonStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(active ? Color.black : Color.orange.opacity(0.95))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.orange : Color.orange.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.4), lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(active ? Color.black : Color.green)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? Color.green : Color.green.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.green.opacity(0.4), lineWidth: 1))
                    // Press highlight — flash bílé overlay během stisku.
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(configuration.isPressed ? 0.15 : 0))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Color.white.opacity(0.75))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Animovaný modifier pro custom-styled tlačítka (OTEVŘÍT VJEZD, Hotovo,
/// Uložit atd.), která používají `.buttonStyle(.plain)` + vlastní background.
/// Aplikuje scale + flash overlay se spring animací při stisku.
struct PressAnimationStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    var flashColor: Color = .white
    var scalePressed: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(flashColor.opacity(configuration.isPressed ? 0.18 : 0))
                    .allowsHitTesting(false)
            )
            .scaleEffect(configuration.isPressed ? scalePressed : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
