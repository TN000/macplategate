import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Verify admin heslo — deleguje na `Auth.shared`.
/// Sentinel konstanta pro `PasswordPromptSheet.expected` — nepoužívá se pro
/// přímé porovnání, ale jako marker že verifikace jde přes Auth.
let SPZAdminPassword: String = "__keychain__"

struct StreamTabView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var cameras: CameraManager
    /// Když non-nil, render pouze této kamery na max prostoru (klik na "oko" v
    /// CameraPane). Ostatní UI (ManualControlBar, RecentCard, druhá pane)
    /// schované — fullscreen-in-window preview s pan/zoom + snap photo.
    @State private var fullPreviewCamera: String? = nil

    var body: some View {
        GeometryReader { geo in
            if let focused = fullPreviewCamera,
               let cam = state.cameras.first(where: { $0.name == focused && $0.enabled }) {
                CameraPane(cameraName: cam.name, paneWidth: geo.size.width - 36,
                           fullPreviewCamera: $fullPreviewCamera)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .padding(.horizontal, 18)
            } else {
                stackBody(geo: geo)
            }
        }
        .onAppear {
            cameras.bind(state: state)
            cameras.sync(cameras: state.cameras)
            WebServer.shared.bindCameras(cameras)
            for (name, svc) in cameras.services where svc.connected {
                cameras.onStreamNominalFpsChanged(for: name)
            }
        }
        .onChange(of: state.cameras) { _, _ in cameras.sync(cameras: state.cameras) }
        .onChange(of: state.detectionRateAuto) { _, _ in cameras.restartAllPipelines() }
        .onChange(of: state.detectionFpsManual) { _, _ in cameras.restartAllPipelines() }
        .onChange(of: state.captureRateAuto) { _, _ in cameras.applyCaptureRateAll() }
        .onChange(of: state.captureFpsManual) { _, _ in cameras.applyCaptureRateAll() }
    }

    @ViewBuilder
    private func stackBody(geo: GeometryProxy) -> some View {
        let enabled = state.cameras.filter { $0.enabled }
        let hPad: CGFloat = 18 * 2
        let spacing: CGFloat = 12
        let contentW = max(240, geo.size.width - hPad)
        let narrow = contentW < 980
        let cameraCols: Int = {
            guard !enabled.isEmpty else { return 1 }
            if narrow { return 1 }
            if enabled.count <= 2 { return enabled.count }
            return geo.size.width < 1400 ? 2 : 3
        }()
        let paneW = min(720, max(240, (contentW - spacing * CGFloat(cameraCols - 1)) / CGFloat(cameraCols))) - 2
        let groupW = paneW * CGFloat(cameraCols) + spacing * CGFloat(max(0, cameraCols - 1))
        let cardHeight: CGFloat = max(320, min(470, paneW * 9.0/16.0 + 56))

        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                ManualControlBar()
                    .frame(width: min(contentW, max(groupW, paneW)), alignment: .leading)

                if enabled.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(DS.Color.textTertiary)
                        Text("Žádná aktivní kamera")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    .frame(width: paneW, height: 180)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.lg)
                            .fill(Color.black.opacity(0.35))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg)
                                .stroke(DS.Color.border, lineWidth: 1))
                    )
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(paneW), spacing: spacing), count: cameraCols),
                        alignment: .center,
                        spacing: spacing
                    ) {
                        ForEach(enabled, id: \.name) { cam in
                            CameraPane(cameraName: cam.name, paneWidth: paneW,
                                       fullPreviewCamera: $fullPreviewCamera)
                                .frame(width: paneW)
                                .clipped()
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                if narrow {
                    VStack(alignment: .center, spacing: spacing) {
                        RecentCard()
                            .frame(width: paneW, height: cardHeight)
                        AllowedPassesCard()
                            .frame(width: paneW, height: cardHeight)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: spacing) {
                        RecentCard()
                            .frame(width: paneW, height: cardHeight)
                        AllowedPassesCard()
                            .frame(width: paneW, height: cardHeight)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Per-camera pane — vlastní panel s background. Header row (label VJEZD/VÝJEZD
/// + informační buňky jako v header stats baru) + stage (stream/ROI crop) +
/// volitelně inline SettingsPanel pod stage.
// CameraPane + StreamStage extracted to UI/Stream/.

// MARK: - Stage

/// Aplikuje `.aspectRatio(_, .fit)` jen pokud `aspect != nil` — jinak no-op.
/// Použití: ve fullPreview chceme content fill celé okno bez aspect omezení
/// (MetalPreviewRenderer letterboxuje interně, takže video drží správný poměr).
// ConditionalAspectRatio extracted to UI/Stream/StreamWidgets.swift.


// FullStreamPreview + FullStreamPreviewVM extracted to UI/Stream/FullStreamPreview.swift.

// RoiCroppedStage + RoiPreviewVM extracted to UI/Stream/RoiCroppedStage.swift.

/// Status overlay uvnitř ROI cropped stage. Dva režimy:
/// - bez čerstvé detekce → centrovaný „NEVIDÍM SPZ" na polopruhledném šedém pozadí
/// - čerstvá detekce (< 3 s) → spodní pás „ZAZNAMENÁN PRŮJEZD" + SPZ na bílém podkladu
// DetectionStatusOverlay extracted to UI/Stream/DetectionStatusOverlay.swift.

/// Centrovaný banner zobrazený když Vision nic nedetekuje.
// NoPlateBanner / CapturedPassBanner / StreamChip extracted to UI/Stream/StreamWidgets.swift.

// MARK: - Settings Panel (expanded pod streamem při zmáčknutí gear ikony)

// SettingsPanel / CompactStatsBar extracted to UI/Stream/.

// Button styles extracted to UI/Stream/ButtonStyles.swift.

// MARK: - Compact stats bar (nahoře nad streamem)

/// Kompaktní stats řádek, styl tmavé pillule. Menší písma než full-size StatsCard
/// aby se vešel do horní lišty nad kamery.

// MARK: - Recent panel (půl šířky okna, 4 viditelné řádky, scroll pro 10)

// RecentCard / AllowedPassesCard / WhitelistEditor / PersonDetailView extracted to UI/Stream/Panels/.
// MARK: - Karta s tab-záložkami (Historie / Seznam / Statistiky)

// MARK: - Whitelist editor (inline v SEZNAM tabu)


// MARK: - Person detail view — kompletní přehled za měsíc


// (FindTab odstraněn — search je nyní inline v SEZNAM tabu přes filter
// `KnownPlates.entries` podle SPZ substring nebo jména s/bez diakritiky.)

// MARK: - Password prompt — potvrzení přidání do whitelistu

// PasswordPromptSheet extracted to UI/Stream/Sheets/PasswordPromptSheet.swift.

// RecentRow extracted to UI/Stream/RecentRow.swift.

/// Sheet pro user override — pokud OCR commit byl chybný, user opraví text
/// → zápis do `replay-overrides.jsonl` přes `ReplayOverrideStore`.
/// Replay engine pak používá `truePlate` jako effective ground truth.
// MarkWrongSheet extracted to UI/Stream/Sheets/MarkWrongSheet.swift.

/// Confidence ring meter — vizuální 0-100% ring v DS palette.
/// Apple Watch / Health activity rings inspirováno.
// ConfidenceRing / RoiSelectHint extracted to UI/Stream/StreamWidgets.swift.

// MARK: - StatsView — souhrnné statistiky využití brány + CSV export

// MARK: - HistoryView — všechny detekce z SQLite s filtrem po datu/SPZ/kameře

// HistoryView extracted to UI/Stream/HistoryView.swift.

// StatsView extracted to UI/Stream/StatsView.swift.

// MARK: - ManualControlBar — úzký panel s manuálními akcemi nad kamerami

// ManualControlBar extracted to UI/Stream/ManualControlBar.swift.

// MARK: - AddDailyPassSheet — přidání dočasné SPZ do whitelistu bez hesla

// AddDailyPassSheet extracted to UI/Stream/Sheets/AddDailyPassSheet.swift.

// PerspectiveCalibrationSheet extracted to UI/Stream/Sheets/PerspectiveCalibrationSheet.swift.


// DetectionAreaSheet extracted to UI/Stream/Sheets/DetectionAreaSheet.swift.
