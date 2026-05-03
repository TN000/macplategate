import SwiftUI

/// Design-system stavební bloky pro Settings tab — sdílené napříč všemi sekcemi.
/// Extracted ze `SettingsView.swift` jako součást big-refactor split (krok #10).
/// Public structs (žádný `private`) — používá je každá Settings sekce.

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    let trailing: AnyView?
    let content: () -> Content

    init(_ title: String, icon: String = "gearshape.fill",
         accent: Color = DS.Color.textTertiary,
         @ViewBuilder trailing: () -> AnyView? = { nil },
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
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 14)
                Text(LocalizedStringKey(title.uppercased()))
                    .font(DS.Typo.cardTitle)
                    .tracking(DS.Typo.cardTitleTracking)
                    .foregroundStyle(DS.Color.textPrimary)
                Spacer(minLength: DS.Space.md)
                if let t = trailing { t }
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

/// Řádek s labelem + hodnotou + +/- steppery (matching horní banner styling).
struct StepperRow<V: Comparable & Numeric>: View {
    let label: String
    let hint: String?
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V
    let formatter: (V) -> String

    init(_ label: String, hint: String? = nil, value: Binding<V>,
         range: ClosedRange<V>, step: V, formatter: @escaping (V) -> String) {
        self.label = label; self.hint = hint
        self._value = value; self.range = range; self.step = step
        self.formatter = formatter
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(label)).font(.system(size: 12, weight: .semibold))
                if let h = hint {
                    Text(LocalizedStringKey(h)).font(.system(size: 10))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            Text(formatter(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 70, alignment: .trailing)
            HStack(spacing: 4) {
                stepBtn(icon: "minus") {
                    let n = value - step
                    if n >= range.lowerBound { value = n }
                }
                stepBtn(icon: "plus") {
                    let n = value + step
                    if n <= range.upperBound { value = n }
                }
            }
        }
    }

    private func stepBtn(icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.12), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}

/// Slider row — kompaktnější (DS.Typo + smaller controlSize).
struct SliderRow: View {
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
                Text(LocalizedStringKey(h)).font(DS.Typo.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Toggle row — single line, .firstTextBaseline align, .small switch.
struct ToggleRow: View {
    let label: String
    let hint: String?
    @Binding var isOn: Bool

    init(_ label: String, hint: String? = nil, isOn: Binding<Bool>) {
        self.label = label; self.hint = hint; self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label)).font(DS.Typo.body).foregroundStyle(DS.Color.textPrimary)
                if let h = hint {
                    Text(LocalizedStringKey(h)).font(DS.Typo.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.md)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch).labelsHidden()
                .controlSize(.small)
        }
    }
}
