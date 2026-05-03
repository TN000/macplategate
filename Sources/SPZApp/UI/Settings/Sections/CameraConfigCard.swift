import SwiftUI
import AppKit

/// CameraConfigCard — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct CameraConfigCard: View {
    @Binding var cam: CameraConfig
    @EnvironmentObject var state: AppState
    @State private var ipDraft: String = ""
    @State private var routeInfo: String = "…"

    var body: some View {
        SettingsCard(
            cam.label, icon: "video.fill",
            accent: cam.enabled ? .green : .gray,
            trailing: {
                AnyView(
                    Toggle("", isOn: $cam.enabled)
                        .toggleStyle(.switch).labelsHidden()
                        .onChange(of: cam.enabled) { _, _ in state.updateCamera(cam) }
                )
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                fieldLabel("RTSP URL")
                TextField("rtsp://user:pass@ip/path", text: $cam.rtspURL,
                          onCommit: { state.updateCamera(cam); refreshRoute() })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(inputBg)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("IP adresa (rychlá změna)")
                    HStack(spacing: 6) {
                        TextField("198.51.100.60", text: $ipDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(inputBg)
                        Button("Uložit IP") {
                            cam.rtspURL = swapIP(in: cam.rtspURL, with: ipDraft)
                            state.updateCamera(cam)
                            refreshRoute()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(ipDraft.isEmpty)
                    }
                }
            }

            // Routing info — který interface dosahuje kameru (Ethernet/WiFi)
            HStack(spacing: 8) {
                Image(systemName: interfaceIcon(routeInfo))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Route přes:").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(LocalizedStringKey(routeInfo))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                Spacer()
                Button {
                    refreshRoute()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(GhostButtonStyle())
            }

            // ROI readout
            HStack {
                fieldLabel("VÝŘEZ")
                Spacer()
                if let r = cam.roi {
                    Text("\(r.width)×\(r.height) @ \(r.x),\(r.y) · \(String(format: "%+.1f°", r.rotationDeg))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.85))
                    Button("Reset") { state.setRoi(name: cam.name, roi: nil) }
                        .buttonStyle(GhostButtonStyle())
                } else {
                    Text("nenastaveno — vyber v tabu Stream")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            ipDraft = currentIP(in: cam.rtspURL)
            refreshRoute()
        }
    }

    private func refreshRoute() {
        let ip = currentIP(in: cam.rtspURL)
        guard !ip.isEmpty else { routeInfo = "—"; return }
        DispatchQueue.global(qos: .utility).async {
            let info = NetworkDiag.routeInterface(forIP: ip)
            DispatchQueue.main.async { self.routeInfo = info }
        }
    }

    private func interfaceIcon(_ info: String) -> String {
        let lower = info.lowercased()
        if lower.contains("en0") || lower.contains("ether") { return "cable.connector" }
        if lower.contains("en1") || lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("airport") { return "wifi" }
        return "network"
    }

    private var inputBg: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.06))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 9, weight: .bold)).tracking(1.3)
            .foregroundStyle(Color.white.opacity(0.45))
    }

    private func currentIP(in url: String) -> String {
        if let m = url.range(of: #"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) {
            return String(url[m])
        }
        return ""
    }
    private func swapIP(in url: String, with newIP: String) -> String {
        let pat = #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#
        guard newIP.range(of: pat, options: .regularExpression) != nil else { return url }
        return url.replacingOccurrences(of: #"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#,
                                        with: newIP, options: .regularExpression)
    }
}

// MARK: - Detection section (rates, OCR, types)
