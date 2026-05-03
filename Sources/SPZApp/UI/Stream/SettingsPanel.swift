import SwiftUI
import AppKit

/// SettingsPanel — expanded settings pod streamem (gear ikona).
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct SettingsPanel: View {
    let cameraName: String
    @Binding var roiSelectMode: Bool
    @Binding var settingsOpen: Bool
    @Binding var showKameraBypass: Bool
    @ObservedObject var camera: CameraService
    @EnvironmentObject var state: AppState

    @State private var coarseDeg: Double = 0
    @State private var showPerspectiveSheet: Bool = false
    @State private var showDetectionSheet: Bool = false
    @State private var showExclusionSheet: Bool = false
    /// Nový 8-DOF interaktivní kalibrátor (PerspectiveCalibrationView).
    @State private var showInteractivePerspective: Bool = false
    /// Zámek poměru Scale Y/X. Při aktivaci se zapamatuje aktuální poměr,
    /// pohyb jednoho slideru poté posouvá druhý PROPORCIONÁLNĚ tak, aby
    /// ratio zůstalo zachované (ne uniform scale).
    @State private var scaleLocked: Bool = false
    @State private var scaleLockedRatio: Double = 1.0  // = Y/X v okamžiku zamčení

    private var myCam: CameraConfig? { state.cameras.first(where: { $0.name == cameraName }) }
    private var roiSet: Bool { myCam?.roi != nil }
    private var totalDeg: Double { myCam?.roi?.rotationDeg ?? 0 }

    /// Slider binding pro scaleX/scaleY — čte a zapisuje scale klíč v perspektivě.
    /// Pokud je `scaleLocked`, zápis do scaleX proporcionálně upraví scaleY
    /// (a vice versa) tak aby se zachoval poměr Y/X zamčený v okamžiku toggle.
    private func perspectiveScaleBinding(keyPath: WritableKeyPath<PerspectiveConfig, Double>) -> Binding<Double> {
        Binding(
            get: { self.myCam?.roi?.perspective?[keyPath: keyPath] ?? (keyPath == \.scaleX || keyPath == \.scaleY ? 1.0 : 0.0) },
            set: { v in
                guard var p = self.myCam?.roi?.perspective else { return }
                p[keyPath: keyPath] = v
                // Proporční zámek: držet Y/X = scaleLockedRatio.
                if scaleLocked {
                    if keyPath == \.scaleX {
                        p.scaleY = v * scaleLockedRatio
                    } else if keyPath == \.scaleY {
                        // Y mění user → X dopočítat tak aby Y/X = ratio.
                        if scaleLockedRatio > 0.001 {
                            p.scaleX = v / scaleLockedRatio
                        }
                    }
                    // Clamp obě v platném range sliderů (0.5–2.0).
                    p.scaleX = max(0.5, min(2.0, p.scaleX))
                    p.scaleY = max(0.5, min(2.0, p.scaleY))
                }
                state.setRoiPerspective(name: cameraName, perspective: p)
            }
        )
    }

    /// Otevře NSOpenPanel pro výběr screenshotu (HEIC/JPG/PNG), naloaduje ho
    /// do `state.frozenFrames[cameraName]` a kalibrační editory ho začnou
    /// používat místo živého streamu.
    private func pickFrozenFrame() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.heic, .jpeg, .png, .image]
        // Default lokace: manual-prujezdy/ — sem se ukládají snap photos.
        panel.directoryURL = Store.shared.manualPassesDir
        panel.message = "Vyber screenshot scény pro \(myCam?.label ?? cameraName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !state.setFrozenFrame(name: cameraName, fromURL: url) {
            FileHandle.safeStderrWrite(
                "[FrozenFrame] selhalo načtení \(url.path)\n".data(using: .utf8)!)
        }
    }

    /// Toggle zámku — při zapnutí zapamatuj aktuální poměr Y/X.
    /// Pracuje nad `PerspectiveCalibration` (8-DOF model). Legacy
    /// `PerspectiveConfig` slidery už v UI nejsou.
    private func toggleScaleLock() {
        if scaleLocked {
            scaleLocked = false
        } else {
            let sx = myCam?.roi?.perspectiveCalibration?.scaleX ?? 1.0
            let sy = myCam?.roi?.perspectiveCalibration?.scaleY ?? 1.0
            scaleLockedRatio = sx > 0.001 ? (sy / sx) : 1.0
            scaleLocked = true
        }
    }

    /// Slider binding pro scale/offset doladění 8-DOF kalibrace.
    /// Při scale-locku proporcionálně upraví druhou osu (jako u staré
    /// `perspectiveScaleBinding`).
    private func calibScaleBinding(keyPath: WritableKeyPath<PerspectiveCalibration, Double>) -> Binding<Double> {
        Binding(
            get: {
                self.myCam?.roi?.perspectiveCalibration?[keyPath: keyPath]
                    ?? (keyPath == \PerspectiveCalibration.scaleX || keyPath == \PerspectiveCalibration.scaleY ? 1.0 : 0.0)
            },
            set: { v in
                guard var c = self.myCam?.roi?.perspectiveCalibration else { return }
                c[keyPath: keyPath] = v
                if scaleLocked {
                    if keyPath == \PerspectiveCalibration.scaleX {
                        c.scaleY = v * scaleLockedRatio
                    } else if keyPath == \PerspectiveCalibration.scaleY,
                              scaleLockedRatio > 0.001 {
                        c.scaleX = v / scaleLockedRatio
                    }
                    c.scaleX = max(0.5, min(2.0, c.scaleX))
                    c.scaleY = max(0.5, min(2.0, c.scaleY))
                }
                state.setRoiPerspectiveCalibration(name: cameraName, calibration: c)
            }
        )
    }
    private var fineBinding: Binding<Double> {
        Binding(
            get: { max(-45, min(45, self.totalDeg - self.coarseDeg)) },
            set: { newFine in
                let clamped = max(-45, min(45, newFine))
                state.setRoiRotation(name: cameraName, degrees: coarseDeg + clamped)
            }
        )
    }

    private func syncCoarseFromTotal() {
        let presets: [Double] = [-180, -90, 0, 90, 180]
        let v = totalDeg
        coarseDeg = presets.min(by: { abs($0 - v) < abs($1 - v) }) ?? 0
    }

    private func setPreset(_ value: Double) {
        coarseDeg = value
        state.setRoiRotation(name: cameraName, degrees: value)
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 12) {
            // Statický snímek — uploadnutý screenshot pro klidnou kalibraci
            // ROI / perspektivy bez nutnosti živé scény s autem.
            HStack(spacing: 8) {
                Text("STATICKÝ SNÍMEK")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if let url = state.frozenFrameURLs[cameraName] {
                    Text(url.lastPathComponent)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1).truncationMode(.middle)
                    Text("AKTIVNÍ")
                        .font(.system(size: 9, weight: .bold)).tracking(1.2)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.cyan))
                }
                Spacer()
                if state.frozenFrameURLs[cameraName] != nil {
                    Button(action: { state.clearFrozenFrame(name: cameraName) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.circle").font(.system(size: 10))
                            Text("Vrátit live").font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                Button(action: { pickFrozenFrame() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 10))
                        Text(state.frozenFrameURLs[cameraName] == nil ? "Vybrat foto…" : "Změnit foto…")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .help("Načti uložený screenshot scény (např. z manual-prujezdy/) a edituj ROI/perspektivu nad ním. Pipeline OCR pojede dál nad živým streamem.")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((state.frozenFrameURLs[cameraName] != nil ? Color.cyan : Color.white).opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke((state.frozenFrameURLs[cameraName] != nil ? Color.cyan : Color.white).opacity(0.18), lineWidth: 1))
            )

            // ROI selection row
            HStack(spacing: 8) {
                Text("OBLAST DETEKCE")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                if roiSelectMode {
                    Button("Zrušit výběr") { roiSelectMode = false }
                        .buttonStyle(GhostButtonStyle())
                } else if roiSet {
                    Button(action: {
                        state.setRoi(name: cameraName, roi: nil)
                        showKameraBypass = false
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                            Text("Zrušit výřez").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button(action: { roiSelectMode = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "viewfinder.rectangular")
                            Text("Znovu vybrat").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(action: { roiSelectMode = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "viewfinder.rectangular")
                            Text("Vybrat výřez kamery").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }

            // Rotační controls — jen když ROI nastaveno a nejsme v select módu
            if roiSet && !roiSelectMode {
                Divider().background(Color.white.opacity(0.08))

                HStack(spacing: 6) {
                    Text("ROTACE")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    rotPresetButton("0°", 0)
                    rotPresetButton("+90°", 90)
                    rotPresetButton("180°", 180)
                    rotPresetButton("−90°", -90)
                }

                HStack(spacing: 10) {
                    Image(systemName: "rotate.3d").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Jemně ±45°").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Slider(value: fineBinding, in: -45...45, step: 0.5)
                    Text(String(format: "%+.1f°", fineBinding.wrappedValue))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                        .frame(width: 56, alignment: .trailing)
                    Text(String(format: "Σ %.1f°", totalDeg))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // PERSPEKTIVA — korekce bočního pohledu kamery. Po rotaci.
                Divider().background(Color.white.opacity(0.08))

                HStack(spacing: 6) {
                    Text("PERSPEKTIVA / NAROVNÁNÍ")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    let persp = myCam?.roi?.perspective
                    let has8Dof = myCam?.roi?.perspectiveCalibration != nil
                    if let p = persp, !p.isIdentity {
                        Text("Aktivní")
                            .font(.system(size: 9, weight: .bold)).tracking(1.2)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green))
                        Button(action: {
                            state.setRoiPerspective(name: cameraName, perspective: nil)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle").font(.system(size: 10))
                                Text("Zrušit").font(.system(size: 11, weight: .semibold))
                            }
                        }.buttonStyle(GhostButtonStyle())
                    }
                    Button(action: { showInteractivePerspective = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "skew").font(.system(size: 10))
                            Text(has8Dof ? "Narovnání ●" : "Narovnat SPZ")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Doporučená 8-DOF kalibrace: označ rohy značky a narovnej ji pro OCR.")
                    if has8Dof {
                        Button(action: {
                            state.setRoiPerspectiveCalibration(name: cameraName, calibration: nil)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle").font(.system(size: 10))
                                Text("8-DOF reset").font(.system(size: 11, weight: .semibold))
                            }
                        }.buttonStyle(GhostButtonStyle())
                    }
                }

                // Doladění 8-DOF: scale (X/Y + zámek poměru) + translace celého
                // výstupu. Slidery se zobrazí jen když je 8-DOF aktivní.
                if let calib = myCam?.roi?.perspectiveCalibration {
                    HStack(spacing: 10) {
                        Text("Scale X")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Slider(value: calibScaleBinding(keyPath: \.scaleX),
                               in: 0.5...2.0, step: 0.01)
                        Button(action: { toggleScaleLock() }) {
                            Image(systemName: scaleLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(scaleLocked ? Color.green : Color.white.opacity(0.35))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(scaleLocked ? "Zámek poměru aktivní — X a Y se mění proporcionálně" : "Uzamknout poměr Y/X")
                        Text(String(format: "%.2f×", calib.scaleX))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack(spacing: 10) {
                        Text("Scale Y")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Slider(value: calibScaleBinding(keyPath: \.scaleY),
                               in: 0.5...2.0, step: 0.01)
                        Spacer().frame(width: 18)
                        Text(String(format: "%.2f×", calib.scaleY))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.85))
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack(spacing: 10) {
                        Text("Posun X")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Slider(value: calibScaleBinding(keyPath: \.offsetX),
                               in: -0.5...0.5, step: 0.005)
                        Text(String(format: "%+.0f %%", calib.offsetX * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack(spacing: 10) {
                        Text("Posun Y")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Slider(value: calibScaleBinding(keyPath: \.offsetY),
                               in: -0.5...0.5, step: 0.005)
                        Text(String(format: "%+.0f %%", calib.offsetY * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.85))
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                // FINÁLNÍ OBLAST DETEKCE — 4-bodový quad uvnitř korigovaného ROI.
                // OCR běží jen v bboxu tohoto quadu (uspora CPU + lepší přesnost).
                Divider().background(Color.white.opacity(0.08))

                HStack(spacing: 6) {
                    Text("OBLAST DETEKCE")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    let dq = myCam?.roi?.detectionQuad
                    if let dq, dq.count == 4 {
                        Text("Aktivní")
                            .font(.system(size: 9, weight: .bold)).tracking(1.2)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green))
                        Button(action: {
                            state.setRoiDetectionQuad(name: cameraName, quad: nil)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle").font(.system(size: 10))
                                Text("Zrušit").font(.system(size: 11, weight: .semibold))
                            }
                        }.buttonStyle(GhostButtonStyle())
                    }
                    Button(action: { showDetectionSheet = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "viewfinder").font(.system(size: 10))
                            Text(dq == nil ? "Kalibrovat" : "Upravit")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }.buttonStyle(PrimaryButtonStyle())
                }

                // MASKY VÝJIMEK — uvnitř detection quad oblasti zamaskovat
                // statické nápisy (banner, logo, cedule) co Vision opakovaně
                // čte a Normalizer odmítá (ale stále plnit log + CPU).
                HStack(spacing: 6) {
                    Text("MASKY VÝJIMEK")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    let masks = myCam?.roi?.exclusionMasks ?? []
                    if !masks.isEmpty {
                        Text("\(masks.count)× ")
                            .font(.system(size: 9, weight: .bold)).tracking(1.2)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange))
                        Button(action: {
                            state.setRoiExclusionMasks(name: cameraName, masks: [])
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark.circle").font(.system(size: 10))
                                Text("Smazat vše").font(.system(size: 11, weight: .semibold))
                            }
                        }.buttonStyle(GhostButtonStyle())
                    }
                    Button(action: { showExclusionSheet = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.dashed").font(.system(size: 10))
                            Text(masks.isEmpty ? "Nakreslit…" : "Upravit")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }.buttonStyle(PrimaryButtonStyle())
                }
                Text("Tažením myši nakresli obdélníky kolem statických nápisů (banner, logo) co OCR opakovaně čte. Vision text observations uvnitř masky se ignorují.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(14)
        }  // ScrollView
        .frame(maxHeight: 420)  // cap panel height, nechá místo pro Hotovo row

        Divider().background(Color.white.opacity(0.08))

        // Fixní bottom action row — vždy viditelný.
        HStack(spacing: 8) {
            Button(action: { camera.forceReconnect() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Restartovat stream").font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(GhostButtonStyle())
            .help("Force reconnect — po změně rozlišení/FPS na kameře")

            Spacer()

            Button(action: { settingsOpen = false }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Hotovo").font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(PrimaryButtonStyle(active: true))
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(14)
        }  // outer VStack
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .onAppear { syncCoarseFromTotal() }
        .onChange(of: cameraName) { _, _ in syncCoarseFromTotal() }
        .sheet(isPresented: $showPerspectiveSheet) {
            PerspectiveCalibrationSheet(
                cameraName: cameraName,
                camera: camera,
                onClose: { showPerspectiveSheet = false }
            )
            .environmentObject(state)
        }
        .sheet(isPresented: $showDetectionSheet) {
            DetectionAreaSheet(
                cameraName: cameraName,
                camera: camera,
                onClose: { showDetectionSheet = false }
            )
            .environmentObject(state)
        }
        .sheet(isPresented: $showExclusionSheet) {
            ExclusionMaskSheet(
                cameraName: cameraName,
                camera: camera,
                onClose: { showExclusionSheet = false }
            )
            .environmentObject(state)
        }
        .sheet(isPresented: $showInteractivePerspective) {
            InteractivePerspectiveCalibration(
                cameraName: cameraName,
                camera: camera,
                isPresented: $showInteractivePerspective
            )
            .frame(minWidth: 900, minHeight: 640)
            .environmentObject(state)
        }
    }

    private func rotPresetButton(_ label: String, _ value: Double) -> some View {
        Button(action: { setPreset(value) }) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(abs(coarseDeg - value) < 0.1 ? Color.black : Color.green)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(abs(coarseDeg - value) < 0.1 ? Color.green : Color.green.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.4), lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }
}
