import SwiftUI

/// Lehké stream widgets — chips, banners, confidence ring, hint overlay.
/// Extracted ze `StreamView.swift` jako součást big-refactor split (krok #10).
/// Žádný @State, jen view modifiers/structs s injekted props — bezpečné pro
/// file-level extract bez chování.

struct ConditionalAspectRatio: ViewModifier {
    let aspect: CGFloat?
    func body(content: Content) -> some View {
        if let a = aspect {
            content.aspectRatio(a, contentMode: .fit)
        } else {
            content
        }
    }
}

/// Středový banner zobrazený když pipeline 2 s neviděla plate (idle stav).
struct NoPlateBanner: View {
    var body: some View {
        Text("NEVIDÍM SPZ")
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .tracking(5.0)
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 30).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.18).opacity(0.80))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            )
    }
}

/// Spodní banner — zvýrazňuje čerstvě zachycenou SPZ. Malý nadpis
/// „ZAZNAMENÁN PRŮJEZD" nad neprůhlednou bílou plackou se SPZ.
struct CapturedPassBanner: View {
    let plate: String
    var body: some View {
        VStack(spacing: 7) {
            Text("DETEKOVANÁ SPZ")
                .font(.system(size: 10, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(Color.white.opacity(0.9))
            Text(plate)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 15/255, green: 15/255, blue: 20/255))
                .padding(.horizontal, 18).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                )
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
    }
}

/// Mini chip indikátor (top-right roh streamu) — mód, fps, status.
struct StreamChip: View {
    let text: String
    let color: Color
    let weight: Font.Weight

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 10, weight: weight, design: .monospaced))
            .foregroundStyle(color.opacity(0.95))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.6))
                    .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
            )
    }
}

/// Confidence-percent kruhový indikátor — zelený 85+, oranžový 60-85, červený jinak.
struct ConfidenceRing: View {
    let value: Float

    private var tint: Color {
        if value >= 0.85 { return DS.Color.success }
        if value >= 0.6 { return DS.Color.warning }
        return DS.Color.danger
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Color.bg2, lineWidth: 1.75)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, value))))
                .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.smooth, value: value)
            // Rounded font má baseline o ~0.5 px níž než geometrické center —
            // jemný shift aby bylo opticky vystředěné.
            Text("\(Int(value * 100))")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .offset(y: -0.3)
        }
    }
}

/// Zelená pilulka s instrukcí — zobrazuje se v headerRow pane během ROI select
/// módu (místo RES/ROI/ROT/MODE buněk). Levá viewfinder ikona pulsuje subtle
/// scale efektem aby dal uživateli vizuální cue že systém čeká na akci.
struct RoiSelectHint: View {
    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder.rectangular")
                .font(.system(size: 12, weight: .bold))
                .scaleEffect(pulse ? 1.15 : 1.0)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )
            Text("TAŽENÍM MYŠI VYBER OBLAST DETEKCE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.0)
            Text("·")
                .font(.system(size: 11, weight: .bold))
                .opacity(0.6)
            Text("ESC = ZRUŠIT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .opacity(0.7)
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(
            Capsule()
                .fill(LinearGradient(colors: [Color.green, Color(red: 0.3, green: 0.85, blue: 0.4)],
                                     startPoint: .leading, endPoint: .trailing))
                .shadow(color: Color.green.opacity(0.4), radius: 8, y: 2)
        )
        .onAppear { pulse = true }
    }
}
