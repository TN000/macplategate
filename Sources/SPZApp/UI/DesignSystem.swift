import SwiftUI

// MARK: - Design System
//
// Centralizovaná typografická + prostorová škála. Všechny UI komponenty
// (`SettingsCard`, `ToggleRow`, status badges, tab pickery) odkazují na tyto
// konstanty. Ladění vzhledu na jednom místě → ripple effect přes celou app.
//
// **Filozofie:** Apple System Settings Sequoia + Linear + Things 3.
//   • Vyšší hustota — žádný "vzdušný" padding (12 px max v cards, 8 px row gaps).
//   • Slabší fonty (.regular pro body, .medium pro labels, .semibold jen pro titles).
//   • Hairline dividers (0.5 pt) místo 1 pt pruhů.
//   • Monochromatic accenty — jen jeden akcent na kartu, ne barvy všude.
//   • Typografická hierarchie 4 úrovně (title / body / secondary / micro).

enum DS {

    // MARK: Spacing scale (4-pt grid)
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 18
        static let xxl: CGFloat = 24
    }

    // MARK: Type scale (named `Typo` because `Type` is reserved)
    enum Typo {
        // Title (uppercase tracked card heading) — refined SF Compact Display.
        static let cardTitle = Font.system(size: 11, weight: .semibold).leading(.tight)
        static let cardTitleTracking: CGFloat = 1.4

        // Section heading — uvnitř karet, sekce v rámci jedné karty.
        static let section = Font.system(size: 9, weight: .semibold).leading(.tight)
        static let sectionTracking: CGFloat = 1.2

        // Body — primary content text.
        static let body = Font.system(size: 12, weight: .medium)
        static let bodyMono = Font.system(size: 12, weight: .medium, design: .monospaced)

        // Secondary — hints, helper text, captions.
        static let caption = Font.system(size: 10, weight: .regular).leading(.tight)
        static let captionMono = Font.system(size: 10, weight: .regular, design: .monospaced)

        // Micro — labels uvnitř badges, status pills.
        static let micro = Font.system(size: 9, weight: .semibold)
        static let microTracking: CGFloat = 1.1

        // Numeric / data — monospaced large for values.
        static let dataLarge = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let dataSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    // MARK: Color tokens
    enum Color {
        // Backgrounds — warmer dark s subtle blue tint, Apple Sequoia feel.
        static let bg0 = SwiftUI.Color(red: 14/255, green: 16/255, blue: 22/255)
        static let bg1 = SwiftUI.Color(white: 0.10)
        static let bg2 = SwiftUI.Color(white: 0.13)

        // Surfaces — glass pseudo-overlay (komponenty kombinují s .ultraThinMaterial).
        static let surfaceTop = SwiftUI.Color.white.opacity(0.06)
        static let surfaceBottom = SwiftUI.Color.white.opacity(0.02)

        // Text — vyšší kontrast pro lepší čitelnost na dark.
        static let textPrimary = SwiftUI.Color.white.opacity(0.96)
        static let textSecondary = SwiftUI.Color.white.opacity(0.62)
        static let textTertiary = SwiftUI.Color.white.opacity(0.40)

        // Borders — viditelnější hairlines (subtle ale ne neviditelné).
        static let border = SwiftUI.Color.white.opacity(0.10)
        static let borderStrong = SwiftUI.Color.white.opacity(0.18)
        static let hairline = SwiftUI.Color.white.opacity(0.08)

        // Status — Apple system colors, vibrant.
        static let success = SwiftUI.Color(red: 50/255, green: 215/255, blue: 75/255)   // SF Green
        static let warning = SwiftUI.Color(red: 255/255, green: 159/255, blue: 10/255)  // SF Orange
        static let danger = SwiftUI.Color(red: 255/255, green: 69/255, blue: 58/255)    // SF Red
        static let info = SwiftUI.Color(red: 10/255, green: 132/255, blue: 255/255)     // SF Blue
        static let accent = SwiftUI.Color(red: 191/255, green: 90/255, blue: 242/255)   // SF Purple — pro highlight
    }

    // MARK: Radii
    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 10
        static let xl: CGFloat = 12
    }

    // MARK: Animation
    enum Motion {
        /// Snappy spring — toggle / segmented pickery / inline state.
        static let snap: Animation = .spring(response: 0.28, dampingFraction: 0.85)
        /// Smooth spring — layout transitions, sheet appears.
        static let smooth: Animation = .spring(response: 0.42, dampingFraction: 0.82)
        /// Hover/focus tint fade.
        static let tint: Animation = .easeOut(duration: 0.15)
    }
}

// MARK: - Reusable button styles

/// Ghost button — minimální styl, hover tint.
struct DSGhostButtonStyle: ButtonStyle {
    @State private var hovering: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(hovering ? DS.Color.bg2 : .clear)
                    .animation(DS.Motion.tint, value: hovering)
            )
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Filled accent button — primary actions.
struct DSPrimaryButtonStyle: ButtonStyle {
    var tint: Color = DS.Color.success
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(tint.opacity(configuration.isPressed ? 0.7 : 1.0))
            )
    }
}

// MARK: - Reusable surfaces

/// Hairline horizontal divider — používá se uvnitř karet pro oddělování řádků.
struct DSHairline: View {
    var body: some View {
        Rectangle().fill(DS.Color.hairline).frame(height: 0.5)
    }
}

/// Pill / chip — kompaktní status indicator.
struct DSPill: View {
    let label: String
    var icon: String? = nil
    var tint: Color = DS.Color.textSecondary
    var dotPulse: Bool = false

    @State private var pulsePhase: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            } else if dotPulse {
                ZStack {
                    Circle()
                        .stroke(tint, lineWidth: 1.0)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulsePhase ? 2.4 : 1.0)
                        .opacity(pulsePhase ? 0 : 0.85)
                        .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false),
                                   value: pulsePhase)
                    Circle().fill(tint).frame(width: 6, height: 6)
                }
                .frame(width: 12, height: 12)
                .onAppear { pulsePhase = true }
            } else {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(LocalizedStringKey(label.uppercased()))
                .font(DS.Typo.micro)
                .tracking(DS.Typo.microTracking)
                .foregroundStyle(tint.opacity(0.95))
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(0.08))
                .overlay(Capsule().stroke(tint.opacity(0.22), lineWidth: 0.5))
        )
    }
}

// MARK: - Card refresh

/// Glassmorphic card surface — `.ultraThinMaterial` blur + subtle gradient
/// + hairline stroke. Apple Sequoia / Vision Pro look.
struct DSCardBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.xl)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: DS.Radius.xl)
                .fill(LinearGradient(colors: [DS.Color.surfaceTop, DS.Color.surfaceBottom],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: DS.Radius.xl)
                .strokeBorder(DS.Color.border, lineWidth: 0.5)
        }
    }
}

/// Refined SettingsCard — glassmorphic, tighter typography. Drop-in replacement
/// pro existing `SettingsCard`.
struct DSCard<Content: View, Trailing: View>: View {
    let title: String
    let icon: String?
    let accent: Color
    let trailing: Trailing
    let content: () -> Content

    init(_ title: String,
         icon: String? = nil,
         accent: Color = DS.Color.textTertiary,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.trailing = trailing()
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.md) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 14)
                }
                Text(LocalizedStringKey(title.uppercased()))
                    .font(DS.Typo.cardTitle)
                    .tracking(DS.Typo.cardTitleTracking)
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: DS.Space.md)
                trailing
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)

            DSHairline()

            VStack(alignment: .leading, spacing: DS.Space.md) {
                content()
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
        }
        .background(DSCardBackground())
    }
}

// MARK: - Refined inline rows

/// Compact toggle row — single line, smaller font, hairline divider built-in.
struct DSToggleRow: View {
    let label: String
    let hint: String?
    @Binding var isOn: Bool

    init(_ label: String, hint: String? = nil, isOn: Binding<Bool>) {
        self.label = label; self.hint = hint; self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label))
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Color.textPrimary)
                if let h = hint {
                    Text(LocalizedStringKey(h))
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.md)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Compact slider row — header + slider + hint.
struct DSSliderRow: View {
    let label: String
    let hint: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    init(_ label: String, hint: String? = nil, value: Binding<Double>,
         range: ClosedRange<Double>, step: Double = 1, unit: String = "") {
        self.label = label; self.hint = hint
        self._value = value; self.range = range; self.step = step; self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(LocalizedStringKey(label)).font(DS.Typo.body).foregroundStyle(DS.Color.textPrimary)
                Spacer()
                Text(String(format: "%.\(step < 1 ? 2 : 0)f \(unit)", value))
                    .font(DS.Typo.dataSmall)
                    .foregroundStyle(DS.Color.success.opacity(0.95))
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .tint(DS.Color.success)
            if let h = hint {
                Text(LocalizedStringKey(h))
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
