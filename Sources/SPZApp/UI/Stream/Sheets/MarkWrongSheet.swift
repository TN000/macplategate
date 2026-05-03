import SwiftUI

/// Sheet pro ruční oprovu OCR commit — uložení do `replay-overrides.jsonl`.
/// User dvakrát-clickne řádek v Recents, otevře se sheet, zadá skutečný text.
/// Replay engine pak použije ground truth pro daný snapshot (fixed / stillWrong).
///
/// Extracted ze `StreamView.swift` jako součást big-refactor split (krok #10).
struct MarkWrongSheet: View {
    let originalPlate: String
    let snapshotPath: String
    @Binding var input: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.orange)
                Text("OZNAČIT JAKO ŠPATNĚ PŘEČTENÉ")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("Aktuální commit: **\(originalPlate)**")
                .font(.system(size: 12))
            Text("Snímek: `\((snapshotPath as NSString).lastPathComponent)`")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("Skutečný text SPZ (oprava):")
                .font(.system(size: 11, weight: .semibold))

            TextField("Skutečný text plate", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .onSubmit { save() }

            Text("Tato oprava se zapíše do `replay-overrides.jsonl`. Replay engine ji pak použije jako ground truth pro tento snímek (match type → fixed / stillWrong).")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Zrušit") { isPresented = false }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Uložit override") { save() }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty
                              || input.uppercased() == originalPlate.uppercased())
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty, !snapshotPath.isEmpty else {
            isPresented = false
            return
        }
        ReplayOverrideStore.append(
            ReplayOverride(snapshotPath: snapshotPath, truePlate: trimmed, markedAt: Date())
        )
        isPresented = false
    }
}
