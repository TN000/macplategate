import SwiftUI
import AppKit

/// RecentRow — řádek v Recents listu se SPZ + crop + meta + actions.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct RecentRow: View {
    let rec: RecentDetection
    /// Když false, JISTOTA cell není zobrazena (použito v kartě PRŮJEZDY).
    var showConfidence: Bool = true
    @EnvironmentObject var state: AppState
    @State private var markWrongOpen: Bool = false
    @State private var markWrongInput: String = ""
    @State private var statsOpen: Bool = false

    /// Barevné odlišení commit zdroje — vjezd = zelená, výjezd = modrá.
    private var cameraColor: Color {
        switch rec.cameraName.lowercased() {
        case "vjezd": return .green
        case "vyjezd", "výjezd": return .blue
        default: return .gray
        }
    }
    private var cameraLabel: String {
        state.cameras.first(where: { $0.name == rec.cameraName })?.label ?? rec.cameraName
    }

    /// Whitelist match s fuzzy snap L≤1 (B↔8, I↔1 OCR chyby ne-false-flag).
    /// Sdíleno mezi všemi color states (unknown entry/exit + daily pass).
    private var matchedEntry: KnownPlates.Entry? {
        KnownPlates.shared.match(rec.plate)
    }

    /// True pouze pro výjezd + SPZ mimo whitelist. Červený podklad v UI = "auto
    /// odjíždí aniž by prošlo kontrolou".
    private var isUnknownExit: Bool {
        guard rec.cameraName == "vyjezd" || rec.cameraName == "výjezd" else { return false }
        return matchedEntry == nil
    }

    /// True pouze pro vjezd + SPZ mimo whitelist. Žlutý podklad = "neznámé auto
    /// vjíždí" (varovný stav, branka se neotevře auto, čekáme na manuální).
    private var isUnknownEntry: Bool {
        guard rec.cameraName == "vjezd" else { return false }
        return matchedEntry == nil
    }

    /// True pokud SPZ má whitelist entry s `expiresAt != nil` — denní průjezd
    /// (časově omezený, typicky 24h, přidaný přes WebUI). Modrý podklad v UI =
    /// "známá SPZ ale jen na dnešek, ne trvale" — vizuálně odlišit od permanentní
    /// whitelist entry.
    private var isDailyPass: Bool {
        matchedEntry?.expiresAt != nil
    }

    /// Priorita: unknown exit (red) > daily pass (blue) > unknown entry (yellow)
    /// > permanentní whitelist (white). Daily pass přebíjí yellow protože SPZ
    /// JE známá, jen časově omezená.
    private var plateBg: Color {
        if isUnknownExit { return DS.Color.danger }
        if isDailyPass { return DS.Color.info }
        if isUnknownEntry { return DS.Color.warning }
        return Color.white
    }

    /// Vehicle badge pod SPZ — kompaktnější, DS tokens.
    @ViewBuilder private var vehicleBadge: some View {
        if rec.vehicleType != nil || rec.vehicleColor != nil {
            let label = [rec.vehicleColor, rec.vehicleType]
                .compactMap { $0 }
                .joined(separator: " ")
            HStack(spacing: 3) {
                Image(systemName: vehicleSFSymbol(for: rec.vehicleType))
                    .font(.system(size: 8))
                if let color = rec.vehicleColor {
                    Circle()
                        .fill(swiftUIColorForName(color))
                        .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
                        .frame(width: 7, height: 7)
                }
                Text(LocalizedStringKey(label))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 92, alignment: .leading)
            }
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(
                Capsule().fill(DS.Color.bg2)
                    .overlay(Capsule().stroke(DS.Color.border, lineWidth: 0.5))
            )
        }
    }

    /// Tinted accent z kamery — DS palette místo raw .green/.blue.
    private var cameraTint: Color {
        switch rec.cameraName.lowercased() {
        case "vjezd": return DS.Color.success
        case "vyjezd", "výjezd": return DS.Color.info
        default: return DS.Color.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Col 1: VJEZD/VYJEZD label (vertikální pilulka, fixed width)
            HStack(spacing: 4) {
                Circle().fill(cameraTint).frame(width: 5, height: 5)
                Text(LocalizedStringKey(cameraLabel.uppercased()))
                    .font(DS.Typo.micro)
                    .tracking(DS.Typo.microTracking)
                    .foregroundStyle(cameraTint.opacity(0.9))
                    .lineLimit(1)
            }
            .frame(width: 64, alignment: .leading)

            // Col 2: snapshot crop
            Group {
                if let img = rec.cropImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            .frame(width: 78, height: 26)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm - 2))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm - 2)
                .stroke(DS.Color.border, lineWidth: 0.5))
            .help(rec.snapshotPath != nil
                  ? "Klik = otevřít snapshot. Right-click = označit jako špatně přečtené."
                  : "Snapshot není uložen")
            .onTapGesture {
                guard let path = rec.snapshotPath else { return }
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            .contextMenu {
                if rec.snapshotPath != nil {
                    Button("Označit jako špatně přečtené…") {
                        markWrongInput = rec.plate
                        markWrongOpen = true
                    }
                    Button("Otevřít snapshot") {
                        if let path = rec.snapshotPath {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                }
            }

            // Col 3: SPZ text (+ vehicle badge pod tím v jediném compact slotu).
            // Fixed width 130 — gridové zarovnání mezi řádky i mezi panely.
            // Klik na plate (když přihlášen) otevře VehicleStatsSheet — počet
            // průjezdů, sessions, history pro libovolnou SPZ (i mimo whitelist).
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.plate)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle((isUnknownExit || isDailyPass) ? Color.white : Color(red: 15/255, green: 15/255, blue: 20/255))
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm - 2)
                            .fill(plateBg)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    )
                vehicleBadge
            }
            .frame(width: 130, alignment: .leading)
            .help(state.isLoggedIn
                  ? "Klik = statistika vozidla (počet průjezdů, sessions, historie)."
                  : "Pro statistiku se přihlas vpravo nahoře.")
            .onTapGesture {
                guard state.isLoggedIn else { return }
                statsOpen = true
            }

            // Col 4: confidence ring (zmenšený o 30 %: 26 → 18)
            if showConfidence {
                ConfidenceRing(value: rec.confidence)
                    .frame(width: 18, height: 18)
            } else {
                // Zachovej grid even při hide confidence (Historie některé tabs).
                Color.clear.frame(width: 18, height: 18)
            }

            // Repeat count chip — between conf a time
            if rec.count > 1 {
                HStack(spacing: 2) {
                    Image(systemName: "repeat")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(rec.count)×")
                        .font(DS.Typo.dataSmall)
                }
                .foregroundStyle(DS.Color.warning.opacity(0.95))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm - 2)
                        .fill(DS.Color.warning.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm - 2)
                            .stroke(DS.Color.warning.opacity(0.32), lineWidth: 0.5))
                )
            }

            Spacer(minLength: DS.Space.sm)

            // Col 5 (vpravo): čas + datum (fixed width 80 + trailing 6 pro
            // konzistentní pozici napříč všemi řádky a panely).
            VStack(alignment: .trailing, spacing: 0) {
                Text(rec.timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.Color.textPrimary)
                Text(rec.timestamp.formatted(.dateTime.day().month(.twoDigits).year(.twoDigits)))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .frame(width: 80, alignment: .trailing)
            .padding(.trailing, 6)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(DS.Color.bg1.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                    .stroke(DS.Color.border, lineWidth: 0.5))
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .sheet(isPresented: $markWrongOpen) {
            MarkWrongSheet(
                originalPlate: rec.plate,
                snapshotPath: rec.snapshotPath ?? "",
                input: $markWrongInput,
                isPresented: $markWrongOpen
            )
        }
        .sheet(isPresented: $statsOpen) {
            VehicleStatsSheet(plate: rec.plate, onClose: { statsOpen = false })
                .environmentObject(state)
        }
    }
}
