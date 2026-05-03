import SwiftUI
import AppKit

/// TrackerSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct TrackerSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        SettingsCard("Upozornění", icon: "exclamationmark.triangle.fill", accent: .yellow.opacity(0.9)) {
            Text("Tato sekce nastavuje jak aplikace rozhoduje kdy si je jistá, že přečetla SPZ správně. Špatné hodnoty vedou buď k chybným záznamům (přečte text, který není SPZ), nebo naopak k tomu, že aplikace nezaznamená vůbec nic. Pokud nevíš co děláš, nech defaulty.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard("Sledování pozice SPZ", icon: "scope", accent: .cyan.opacity(0.8)) {
            SliderRow("Tolerance pohybu",
                      hint: "Jak moc se smí SPZ na obraze pohnout mezi dvěma snímky, aby ji aplikace považovala za stejnou. Nižší hodnota = snese rychlejší auta; vyšší = přísnější, ale stabilnější při pomalém pohybu. Rozumný rozsah 0,2–0,4.",
                      value: $state.trackerIouThreshold, range: 0.1...0.7, step: 0.05)
            StepperRow("Zapomenout po neviditelnosti",
                       hint: "Pokud SPZ zmizí ze záběru (např. auto odjelo), po kolika snímcích ji aplikace přestane sledovat. Při 10 snímcích/s znamená 10 hodnota 1 sekundu.",
                       value: $state.trackerMaxLostFrames, range: 1...60, step: 1) {
                "\($0) snímků"
            }
        }

        SettingsCard("Kdy zaznamenat SPZ", icon: "checkmark.circle.fill", accent: .green.opacity(0.8)) {
            StepperRow("Minimálně snímků",
                       hint: "Kolikrát musí aplikace vidět stejnou SPZ, než ji zaznamená. Nižší = zachytí i krátké průjezdy (ale víc chyb); vyšší = spolehlivější, ale může propustit rychlé auto.",
                       value: $state.trackerMinHitsToCommit, range: 1...20, step: 1) {
                "\($0)"
            }
            StepperRow("Vynutit zápis po",
                       hint: "I když aplikace stále váhá, po tomto počtu úspěšných čtení zaznamená SPZ automaticky. 0 = funkce vypnutá (rozhoduje jen sledovací algoritmus).",
                       value: $state.trackerForceCommitAfterHits, range: 0...50, step: 1) {
                $0 == 0 ? "vypnuto" : "\($0)"
            }
        }

        SettingsCard("Hlasování o správném znění", icon: "checkmark.seal.fill", accent: .indigo.opacity(0.8)) {
            StepperRow("Minimum shodných čtení",
                       hint: "Aplikace čte SPZ opakovaně z každého snímku. Tohle je počet čtení, která se musí shodnout na stejném textu, než aplikace uzná výsledek. Vyšší = méně omylů.",
                       value: $state.trackerMinWinnerVotes, range: 1...10, step: 1) {
                "\($0)"
            }
            SliderRow("Shoda mezi čteními",
                      hint: "Jaké procento všech čtení musí souhlasit. Např. 0,65 = 65 % čtení musí vrátit stejný text. Vyšší hodnota = přísnější, ale může ignorovat SPZ, kde kamera střídavě chybuje.",
                      value: $state.trackerMinWinnerVoteShare, range: 0.3...1.0, step: 0.05)
            SliderRow("Min. velikost SPZ pro snímek",
                      hint: "SPZ musí zabírat alespoň N % šířky výřezu, než se uloží snímek. Vyšší = auto musí být blíž ke kameře (lepší detail na fotce). 0 = vypnuto (snímek kdykoliv).",
                      value: $state.trackerMinPlateWidthFraction, range: 0.0...0.30, step: 0.01)
            SliderRow("Kolikrát počkat (jistota)",
                      hint: "Pokud SPZ zůstane pod min. velikostí, po kolika × 'Force commit' hitů commit-nout i tak. Vyšší = déle čekat na blíž, nižší = commit dříve i s malou SPZ. 0 = nikdy force (jen LOST cesta).",
                      value: $state.trackerMinPlateWidthSafetyMult, range: 0.0...10.0, step: 0.5)
        }

        SettingsCard("Obnovit doporučené", icon: "arrow.counterclockwise", accent: .red.opacity(0.7)) {
            HStack {
                Text("Vrátí všechny hodnoty na původní rozumné výchozí hodnoty.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Obnovit") {
                    state.trackerIouThreshold = 0.3
                    state.trackerMaxLostFrames = 10
                    state.trackerMinHitsToCommit = 2
                    state.trackerForceCommitAfterHits = 6
                    state.trackerMinWinnerVotes = 3
                    state.trackerMinWinnerVoteShare = 0.65
                    state.trackerMinPlateWidthFraction = 0.12
                    state.trackerMinPlateWidthSafetyMult = 3.0
                }
                .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

// MARK: - Known plates
