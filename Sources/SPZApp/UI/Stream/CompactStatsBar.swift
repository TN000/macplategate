import SwiftUI

/// CompactStatsBar — top status pill nad kamerami.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct CompactStatsBar: View {
    @EnvironmentObject var state: AppState

    /// Dvouřádkové staty — nadpis nahoře (micro uppercase), hodnota dole
    /// (monospaced). Fixed per-column width → žádné skákání layoutu při změně hodnot.
    private static let widths: [String: CGFloat] = [
        "ZACHYCENÍ": 82,
        "DETEKCE":   72,
        "VÝPOČET":   72,
        "HIT":       42,
        "DNES":      48,
        "CELKEM":    64,
    ]

    var body: some View {
        HStack(spacing: DS.Space.md) {
            stat("ZACHYCENÍ", String(format: "%.1f", state.pipelineStats.captureFps), unit: "fps")
            divider
            stat("DETEKCE", String(format: "%.1f", state.pipelineStats.detectFps), unit: "fps")
            divider
            stat("VÝPOČET", "\(Int(state.pipelineStats.ocrLatencyMs))", unit: "ms")
            divider
            ForEach(state.cameras.filter { $0.enabled }, id: \.name) { cam in
                thresholdStepper(for: cam)
                divider
            }
            recommitDelayStepper
        }
        .padding(.vertical, 5)
        .padding(.horizontal, DS.Space.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                    .stroke(DS.Color.border, lineWidth: 0.5))
        )
    }

    private var divider: some View {
        Rectangle().fill(DS.Color.hairline).frame(width: 0.5, height: 22)
    }

    /// Per-camera min velikost detekce (Vision observation height fraction).
    /// Label = camera short name (VJEZD/VÝJEZD) + MIN. Hodnota uložená per-camera.
    /// Range 2–25 %, krok ±1 %.
    private func thresholdStepper(for cam: CameraConfig) -> some View {
        let value = cam.ocrMinObsHeightFraction
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MIN \(cam.label.uppercased())")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text("%")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .frame(minWidth: 64, alignment: .leading)
            VStack(spacing: 2) {
                stepperButton(icon: "plus") {
                    let v = min(0.25, value + 0.01)
                    state.setCameraMinObs(name: cam.name, value: (v * 100).rounded() / 100)
                }
                stepperButton(icon: "minus") {
                    let v = max(0.02, value - 0.01)
                    state.setCameraMinObs(name: cam.name, value: (v * 100).rounded() / 100)
                }
            }
        }
    }

    /// Delay (sekundy) absence před povolenou opakovanou detekcí stejné SPZ.
    /// Range 3–300 s, krok +/-: <10 po 1 s, 10–60 po 5 s, 60+ po 15 s.
    private var recommitDelayStepper: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ZPOŽDĚNÍ")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.white.opacity(0.45))
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(Int(state.recommitDelaySec))")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text("s")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .frame(width: 55, alignment: .leading)
            VStack(spacing: 2) {
                stepperButton(icon: "plus") {
                    let v = state.recommitDelaySec
                    let step: Double = v < 10 ? 1 : (v < 60 ? 5 : 15)
                    state.recommitDelaySec = min(300, v + step)
                }
                stepperButton(icon: "minus") {
                    let v = state.recommitDelaySec
                    let step: Double = v <= 10 ? 1 : (v <= 60 ? 5 : 15)
                    state.recommitDelaySec = max(3, v - step)
                }
            }
        }
    }

    private func stepperButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 16, height: 12)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.12), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private func stat(_ k: String, _ v: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(k))
                .font(DS.Typo.micro)
                .tracking(DS.Typo.microTracking)
                .foregroundStyle(DS.Color.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(v)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if let u = unit {
                    Text(u)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
        }
        .frame(width: Self.widths[k] ?? 60, alignment: .leading)
    }
}
