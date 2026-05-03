import SwiftUI
import AppKit

/// CamerasSection — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct CamerasSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ForEach($state.cameras) { $cam in
            CameraConfigCard(cam: $cam)
        }
        SettingsCard("Info", icon: "info.circle", accent: .blue.opacity(0.8)) {
            Text("ROI (oblast detekce) a rotace se nastavují v tabu Stream — ikona ozubeného kolečka ve streamu. Po změně IP klikni tlačítko Uložit IP.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
