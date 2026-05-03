import SwiftUI
import AppKit

/// DetectionSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct DetectionSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingsCard("Frekvence zachycení", icon: "camera.fill", accent: .green.opacity(0.8)) {
            ToggleRow("Automaticky dle kamery",
                      hint: "Aplikace sama přečte kolik snímků za vteřinu kamera posílá (např. 10) a použije tu hodnotu. Doporučeno nechat zapnuté — odškrtni jen pokud chceš snížit zátěž CPU.",
                      isOn: $state.captureRateAuto)
            if !state.captureRateAuto {
                SliderRow("Ručně snímků za vteřinu", value: $state.captureFpsManual,
                          range: 1...30, step: 1, unit: "sn/s")
            }
            HStack {
                Text("Aktuálně:").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(String(format: "%.1f sn/s", state.pipelineStats.captureFps))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
            }
        }

        SettingsCard("Frekvence detekce", icon: "eye.fill", accent: .orange.opacity(0.8)) {
            ToggleRow("Automaticky",
                      hint: "Stejná frekvence jako zachycení (viz výše). Odškrtni pokud chceš čtení SPZ provádět méně často než příjem snímků — šetří to CPU.",
                      isOn: $state.detectionRateAuto)
            if !state.detectionRateAuto {
                SliderRow("Ručně snímků za vteřinu", value: $state.detectionFpsManual,
                          range: 1...30, step: 1, unit: "sn/s")
            }
            HStack {
                Text("Aktuálně:").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(String(format: "%.1f sn/s · %d ms", state.pipelineStats.detectFps, Int(state.pipelineStats.ocrLatencyMs)))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
            }
        }

        SettingsCard("Úsporný režim", icon: "bolt.slash.fill", accent: .purple.opacity(0.8)) {
            ToggleRow("Aktivní",
                      hint: "Když není po nastavenou dobu detekována žádná SPZ, aplikace sníží frekvenci OCR čtení na nastavenou idle hodnotu. Tím se šetří CPU/ANE/energie. Jakmile Vision detekuje motion nebo plate, okamžitě naběhne zpět na plnou rychlost.",
                      isOn: $state.idleModeEnabled)
            if state.idleModeEnabled {
                SliderRow("Přepnout po",
                          hint: "Po jaké době neaktivity (sekundy bez Vision detekce) přepnout do úsporného režimu. 2 s je rozumné — kratší znamená časté přepínání, delší znamená menší úsporu.",
                          value: $state.idleAfterSec, range: 1.0...30.0, step: 0.5, unit: "s")
                SliderRow("Cílové fps v úspoře",
                          hint: "OCR fps během úsporného režimu. 1 fps = 1 OCR cyklus za vteřinu, výrazná úspora. Vyšší hodnota (2–5) sníží reakční čas na auto vjíždějící do scény bez motion detekce. 0.5 fps je maximální úspora ale auto by mohlo mezi tiky projet.",
                          value: $state.idleDetectionFps, range: 0.5...5.0, step: 0.5, unit: " fps")
            }
        }

        SettingsCard("Noční pauza detekce", icon: "moon.fill", accent: .indigo.opacity(0.8)) {
            ToggleRow("Aktivní",
                      hint: "V nastaveném časovém okně se úplně zastaví OCR / commit / webhook na obou kamerách. Stream + náhled běží dál (žádný reconnect). Použití: pokud se brána mechanicky uzavře (zámek, závora) a nemá smysl detekovat. Pokud začátek > konec, okno přechází přes půlnoc (např. 23 → 5 znamená 23:00–04:59).",
                      isOn: $state.nightPauseEnabled)
            if state.nightPauseEnabled {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("Od").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                        Picker("", selection: $state.nightPauseStartHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)
                    }
                    HStack(spacing: 6) {
                        Text("Do").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                        Picker("", selection: $state.nightPauseEndHour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%02d:00", h)).tag(h)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)
                    }
                    Spacer()
                    if state.isInNightPause() {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.fill").font(.system(size: 9)).foregroundStyle(.indigo)
                            Text("Pauza právě aktivní")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.indigo.opacity(0.9))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }

        SettingsCard("Filtr čtení SPZ", icon: "slider.horizontal.3", accent: .yellow.opacity(0.8)) {
            Text("Minimální velikost textu se nastavuje zvlášť pro každou kameru (vjezd a výjezd mají často různou perspektivu a velikost plate).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(state.cameras.filter { $0.enabled }, id: \.name) { cam in
                SliderRow("Min. velikost textu — \(cam.label)",
                          hint: "Jak velký musí být text v záběru kamery \(cam.label), aby ho aplikace zkusila přečíst. Menší = čte i drobnější plate (ale víc omylů); větší = ignoruje malé texty (loga, cedule). 0,05 je rozumný základ.",
                          value: Binding(
                            get: { cam.ocrMinObsHeightFraction },
                            set: { state.setCameraMinObs(name: cam.name, value: $0) }
                          ), range: 0.012...0.25, step: 0.005)
            }
            Divider().background(Color.white.opacity(0.06))
            StepperRow("Opakovat stejnou SPZ po",
                       hint: "Jak dlouho čekat než stejné auto může být zaznamenáno znovu. Platí pro obě kamery. Auto stojící před závorou by jinak spustilo desítky záznamů. 15 s je typické.",
                       value: $state.recommitDelaySec, range: 3...300, step: 1) {
                "\(Int($0)) s"
            }
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Rychlý režim čtení",
                      hint: "Zapne Apple Vision .fast model místo .accurate. Výsledek: ~2× rychlejší detekce (~14 fps vs ~7 fps per kamera), ale o ~10–15 % nižší přesnost na šikmých/špinavých SPZ. Pro firemní vjezd s čistým výhledem v pohodě; pro kameru sledující ulici z dálky raději nech vypnuté. Apple Vision framework vnitřně serializuje všechny OCR požadavky — proto jediná cesta k vyššímu fps je rychlejší model.",
                      isOn: $state.ocrFastMode)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Dvojité čtení (2× přesnější)",
                      hint: "Pustí na každý frame DVA Vision requesty paralelně (revision3 + revision2). Starší revize 2 občas chytne co revision3 mine a naopak → voting přes obě zvýší přesnost o 2–4 % na okrajových případech (špinavé / šikmé plate). FPS se sníží (~50 %), ANE využití se zvýší (~2×). Funguje pouze v přesném režimu (rychlý režim musí být vypnutý).",
                      isOn: $state.ocrDualPassEnabled)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Rectangle pre-filter (méně falešných)",
                      hint: "Před text OCR spustí VNDetectRectanglesRequest, pak propouští jen observations uvnitř plate-shape rectangles (aspect 2.5–7:1). Filtruje false positives z okolních nápisů (VCHOD, FASE) na noisy background. Účtujeme ~5 ms Vision call navíc per OCR frame.",
                      isOn: $state.useRectanglePrefilter)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Apple Intelligence verifikace (macOS 26+)",
                      hint: "Pro commits s confidence < 0.85 spustí on-device LLM (Apple Intelligence) co zkoriguje OCR chyby (B↔8, O↔0, I↔1 atd.). Inference běží na ANE, ~200–500 ms per low-confidence commit, 1 s timeout. Accept korekce jen když je v známých SPZ nebo projde CZ/SK format validátorem.",
                      isOn: $state.useFoundationModelsVerification)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Rozpoznání typu + barvy vozidla",
                      hint: "K každému commitu přidá vehicle type (SUV/truck/van/bus/motorcycle/car) a dominantní barvu (black/white/red/blue/silver/gray atd.) extrahovanou z crop image. Apple Vision VNClassifyImage (Imagenet-1K) + CIAreaAverage color. ~10 ms per commit na ANE/GPU. Zobrazí se v RecentRow pod SPZ.",
                      isOn: $state.useVehicleClassification)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Plate super-resolution (GPU)",
                      hint: "Swin2SR ML upscaler 4× pro snapshot quality. Běží jen na GPU/CPU (CoreML EP s useCPUAndGPU=true) → žádná contention s Vision OCR na ANE. Cena ~80 ms/snapshot, 32 MB model. Master kill-switch pro celý SR layer (snapshot + OCR shadow + live OCR). Default ON.",
                      isOn: $state.usePlateSuperResolution)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Vývojářské logy (verbose trace)",
                      hint: "Podrobný per-frame log do ~/Library/Application Support/MacPlateGate/spz.log — preprocess luminance, Vision timing, obs count, normalizer raw/basic text, motion detection, vehicle color sample RGB atd. ~20 MB/hodinu log IO, VYPNOUT v produkci.",
                      isOn: $state.devLogging)
        }

        SettingsCard("Vylepšené čtení (pass 2)", icon: "text.viewfinder", accent: .green.opacity(0.8)) {
            ToggleRow("Použít enhanced retry jako hlavní čtečku",
                      hint: "Pass 1 najde oblast textu, pass 2 přečte tight výřez s lokální úpravou jasu a kontrastu. Když enhanced čtení projde CZ/SK validací, dostane přednost v hlasování.",
                      isOn: $state.enhancedRetryEnabled)
            Divider().background(Color.white.opacity(0.06))
            SliderRow("Spustit retry pod confidence",
                      hint: "Vyšší práh pustí pass 2 i na sebevědomá, ale často chybná Vision čtení typu 0↔3, B↔8 nebo S↔5. 0,95 je konzervativní default pro M4.",
                      value: $state.enhancedRetryThreshold,
                      range: 0.80...0.99, step: 0.01)
            Divider().background(Color.white.opacity(0.06))
            SliderRow("Váha enhanced hlasu",
                      hint: "Kolikrát silnější je pass 2 hlas proti běžnému pass 1 hlasu. Nezahazuje raw čtení, jen posouvá rozhodování ke zřetelnějšímu cropu.",
                      value: $state.enhancedVoteWeight,
                      range: 1.0...3.0, step: 0.05)
            Divider().background(Color.white.opacity(0.06))
            SliderRow("Váha raw hlasu při překryvu",
                      hint: "Když pass 1 a pass 2 míří na stejnou oblast, raw hlas se zjemní. Bez překryvu zůstává raw hlas plný, aby se neztratil druhý objekt v záběru.",
                      value: $state.baseVoteWeightWhenEnhancedOverlap,
                      range: 0.0...1.0, step: 0.05)
            Divider().background(Color.white.opacity(0.06))
            StepperRow("Maximum enhanced výřezů",
                       hint: "Kolik Y-clusterů textu může pass 2 znovu číst v jednom OCR ticku. 2 pokryje SPZ + okrajový druhý objekt bez zbytečného ANE tlaku.",
                       value: $state.enhancedRetryMaxBoxes,
                       range: 1...4, step: 1) {
                "\($0)"
            }
        }

        SettingsCard("Sekundární OCR engine", icon: "checkmark.seal.fill", accent: .mint.opacity(0.8)) {
            ToggleRow("Použít sekundární OCR plugin",
                      hint: "Vypínatelný druhý OCR engine pro cross-validaci textu na výřezu SPZ. Běží přes ONNX Runtime, bez CoreML konverze. Když model není přibalený, chování detekce se nemění.",
                      isOn: $state.useSecondaryEngine)
            Divider().background(Color.white.opacity(0.06))
            SliderRow("Váha cross-validovaného hlasu",
                      hint: "Když se Apple Vision a sekundární engine shodnou, čtení dostane vyšší váhu v trackeru. 2,0 odpovídá zhruba dvěma nezávislým potvrzením v jednom frame.",
                      value: $state.crossValidatedVoteWeight,
                      range: 1.0...3.0, step: 0.05)
            Divider().background(Color.white.opacity(0.06))
            infoRow("Plugin", "fast-plate-ocr cct-xs-v2 global")
            infoRow("Runtime", "ONNX Runtime")
        }

        SettingsCard("Typy značek", icon: "text.badge.checkmark", accent: .blue.opacity(0.8)) {
            ToggleRow("Značky na přání (6–8 znaků)",
                      hint: "Tzv. vanity SPZ — vlastní text zvolený majitelem (např. AHOJSVET). Pokud v provozu žádnou takovou značku nečekáš, nech vypnuté — jinak riskuješ, že aplikace chybně přečte reklamní text jako SPZ.",
                      isOn: $state.allowVanityPlates)
            Divider().background(Color.white.opacity(0.06))
            ToggleRow("Zahraniční značky (DE/AT/PL/IT/ES)",
                      hint: "Německo, Rakousko, Polsko, Itálie, Španělsko. Typicky ve formátu s pomlčkou (např. B-AB 1234). Pokud potkáš zahraniční auta, nech zapnuté.",
                      isOn: $state.allowForeignPlates)
        }

        SettingsCard("Použité technologie", icon: "cpu", accent: .purple.opacity(0.8)) {
            infoRow("Engine čtení", "Apple Vision (Neural Engine)")
            infoRow("Sekundární OCR", state.useSecondaryEngine ? "FastPlateOCR ONNX" : "vypnuto")
            infoRow("Záchrana", "top 3 kandidáti z každého pohledu")
            infoRow("Normalizace", "CZ formát — zaměňuje O↔0 dle pozice")
            infoRow("Sledování", "překryv + hlasování + shoda textu")
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k.uppercased()).font(.system(size: 9, weight: .bold))
                .tracking(1.2).foregroundStyle(Color.white.opacity(0.45))
            Spacer()
            Text(v).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
        }
    }
}

// MARK: - Tracker advanced
