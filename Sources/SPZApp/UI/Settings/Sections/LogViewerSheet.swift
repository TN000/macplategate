import SwiftUI
import AppKit

/// LogViewerSheet — extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

struct LogViewerSheet: View {
    let onClose: () -> Void
    @State private var logLines: [String] = []
    @State private var isLoading: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22)).foregroundStyle(Color.cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("APLIKAČNÍ LOG").font(.system(size: 10, weight: .bold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text("~/Library/Application Support/MacPlateGate/spz.log")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reload") { load() }.buttonStyle(GhostButtonStyle())
                Button("Otevřít ve Finderu") {
                    NSWorkspace.shared.activateFileViewerSelecting([Self.logURL])
                }.buttonStyle(GhostButtonStyle())
            }

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(colorFor(line: line))
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .onAppear {
                            if let last = logLines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
                .background(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            HStack {
                Text("\(logLines.count) řádků")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Zavřít") { onClose() }
                    .buttonStyle(PrimaryButtonStyle(active: true))
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 900, height: 650)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .onAppear { load() }
    }

    private func colorFor(line: String) -> Color {
        if line.contains("FAILED") || line.contains("err:") || line.contains("error") { return .red.opacity(0.9) }
        if line.contains("[Commit]") { return .green.opacity(0.9) }
        if line.contains("[Webhook]") { return .cyan.opacity(0.9) }
        if line.contains("[Auth]") { return .yellow.opacity(0.8) }
        if line.contains("[CameraService]") { return .orange.opacity(0.75) }
        return .primary.opacity(0.85)
    }

    private func load() {
        isLoading = true
        let path = Self.logURL
        Task.detached {
            let lines = (try? String(contentsOf: path, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(200)
                .map(String.init) ?? ["(log je prázdný nebo nedostupný)"]
            await MainActor.run {
                self.logLines = lines
                self.isLoading = false
            }
        }
    }

    private static var logURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return appSupport.appendingPathComponent("SPZ/spz.log")
    }
}
