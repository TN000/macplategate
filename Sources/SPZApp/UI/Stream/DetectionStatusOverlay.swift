import SwiftUI

/// DetectionStatusOverlay — zobrazuje "NEVIDÍM SPZ" / CapturedPassBanner overlay nad streamem.
/// Extracted ze StreamView.swift jako součást big-refactor split (krok #10).

struct DetectionStatusOverlay: View {
    @EnvironmentObject var state: AppState
    let cameraName: String
    @State private var now: Date = Date()

    var body: some View {
        // Fresh detection od JEJÍ kamery (per-pane identita).
        let last = state.recents.items.first(where: { $0.cameraName == cameraName })
        let age = last.map { now.timeIntervalSince($0.timestamp) } ?? .greatestFiniteMagnitude
        let fresh = age < 3.0
        // „NEVIDÍM SPZ" skryj i když Vision zrovna vidí znacku na TÉTO kameře.
        let visionSeesPlate = !(state.liveDetectionsByCamera[cameraName] ?? []).isEmpty

        ZStack {
            if fresh, let l = last {
                VStack {
                    Spacer()
                    CapturedPassBanner(plate: l.plate)
                        .padding(.bottom, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !visionSeesPlate {
                NoPlateBanner()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: fresh)
        // TimelineView refreshuje jen pokud view žije — zastaví se na .onDisappear.
        .background(TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            Color.clear.onChange(of: context.date) { _, new in now = new }
        })
        .allowsHitTesting(false)
    }
}
