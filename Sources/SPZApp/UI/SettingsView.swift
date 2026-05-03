import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsTabView: View {
    @EnvironmentObject var state: AppState
    @State private var subTab: SubTab = .cameras

    enum SubTab: String, CaseIterable, Identifiable {
        case cameras = "Kamery"
        case detection = "Detekce"
        case tracker = "Tracker"
        case known = "Známé SPZ"
        case webhook = "Webhook"
        case storage = "Úložiště"
        case manual = "Manuální"
        case network = "Síť"
        case security = "Zabezpečení"
        case about = "O aplikaci"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .cameras: return "video.fill"
            case .detection: return "eye.fill"
            case .tracker: return "scope"
            case .known: return "star.fill"
            case .webhook: return "link"
            case .storage: return "internaldrive.fill"
            case .manual: return "lock.open.fill"
            case .network: return "network"
            case .security: return "lock.shield.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    @Namespace private var subTabPicker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sub-tab header — animated segmented picker matchedGeometryEffect.
            HStack(spacing: 0) {
                ForEach(SubTab.allCases) { st in
                    let active = subTab == st
                    Button(action: {
                        withAnimation(DS.Motion.snap) { subTab = st }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: st.icon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(LocalizedStringKey(st.rawValue)).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(active ? Color.black : DS.Color.textSecondary)
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, 5)
                        .background(
                            ZStack {
                                if active {
                                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                                        .fill(DS.Color.success)
                                        .matchedGeometryEffect(id: "activeSubTab", in: subTabPicker)
                                }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(DS.Color.bg2.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                        .stroke(DS.Color.border, lineWidth: 0.5))
            )
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    switch subTab {
                    case .cameras: CamerasSection()
                    case .detection: DetectionSection()
                    case .tracker: TrackerSection()
                    case .known: KnownPlatesSection()
                    case .webhook: WebhookSection()
                    case .storage: StorageSection()
                    case .manual: ManualPassesSection()
                    case .network: NetworkSection()
                    case .security: SecuritySection()
                    case .about: AboutSection()
                    }
                }
                .padding(DS.Space.xl)
                .transition(.opacity)
                .id(subTab)  // forces fresh transition na change
            }
        }
    }
}

// MARK: - Shared card components — refined design system (DS.*)

/// Card wrapper — kompaktnější padding, jemnější typografie (11/13 → 10/11),
/// hairline border 0.5pt. Public API zachována, vzhled je tighter.
// SettingsCard / StepperRow / SliderRow / ToggleRow extracted to
// UI/Settings/SettingsDesignSystem.swift.

// MARK: - Cameras section















// generateStrongPassword extracted to Utilities/PasswordGenerator.swift.

// Sections + NetworkDiag extracted to UI/Settings/Sections/ + Networking/NetworkDiag.swift.
