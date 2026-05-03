import SwiftUI

/// SwiftUI Previews — `#Preview` makra (Xcode 15+) pro iteraci UI bez build-run cyklu.
///
/// **Use:** otevři projekt v Xcode (`bash scripts/xcode-dev.sh`), Editor → Canvas (⌥⌘↩).
/// Každý `#Preview` blok se vyrenderuje live v canvas panelu vedle kódu.
///
/// **Důležité:** skutečné production views (StreamView, SettingsView) používají
/// `@EnvironmentObject var state: AppState` + `PlatePipeline` + live RTSP stream,
/// což není trivial v preview kontextu. Místo toho tu máme:
/// - Button style previews (izolované SwiftUI komponenty)
/// - Sample data / layout sandboxes pro iteraci stylování
///
/// Rozšířit o konkrétní view preview = buď mockovat AppState (dnes chybí public init),
/// nebo udělat ten view `internal` přijímající dependency injection.

#Preview("Button styles — primary + ghost") {
    VStack(spacing: 12) {
        Button("Primary action") {}.buttonStyle(PrimaryButtonStyle())
        Button("Ghost action") {}.buttonStyle(GhostButtonStyle())
        Button("Press me") {}.buttonStyle(PressAnimationStyle())
    }
    .padding(24)
    .frame(width: 280)
    .background(Color(white: 0.12))
}

#Preview("ToggleButton — active + inactive") {
    HStack(spacing: 12) {
        Button("Active") {}.buttonStyle(ToggleButtonStyle(active: true))
        Button("Inactive") {}.buttonStyle(ToggleButtonStyle(active: false))
    }
    .padding(24)
    .background(Color(white: 0.12))
}

#Preview("Sample plate colors — CZ/SK/foreign") {
    VStack(alignment: .leading, spacing: 8) {
        plateChip("7ZF1234", region: "CZ", color: .green)
        plateChip("EL165CN", region: "SK", color: .blue)
        plateChip("WOBZK295", region: "DE", color: .orange)
        plateChip("5U6", region: "CZ*", color: .purple)
    }
    .padding(24)
    .frame(width: 340)
    .background(Color(white: 0.08))
}

@ViewBuilder
private func plateChip(_ plate: String, region: String, color: Color) -> some View {
    HStack(spacing: 10) {
        Text(region)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        Text(plate)
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
        Spacer()
    }
}
