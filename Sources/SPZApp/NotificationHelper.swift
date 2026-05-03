import Foundation
import UserNotifications

/// Jednoduchý wrapper kolem UserNotifications pro posting user notifications
/// při důležitých eventech (manuální otevření brány, commit detekce atd.).
/// Lazy auth request — při prvním pokusu o post se zeptá na permission.
@MainActor
enum NotificationHelper {
    /// Autorizace requested? Drží stav v memory pro ne-dotazování opakovaně.
    private static var authRequested = false
    private static var authGranted = false

    private static func ensureAuth() async {
        if authRequested { return }
        authRequested = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            authGranted = granted
        } catch {
            FileHandle.safeStderrWrite(
                "[Notify] auth request failed: \(error)\n".data(using: .utf8)!)
            authGranted = false
        }
    }

    /// Post notifikaci — async, silent fail pokud user auth odmítl.
    static func post(title: String, body: String, sound: Bool = true) {
        Task {
            _ = await postAsync(title: title, body: body, sound: sound)
        }
    }

    /// Async variant co vrací true pokud notifikace byla skutečně odeslána do
    /// UserNotifications. ErrorNotifier ji používá pro "stamp dedupe jen když
    /// se doručilo" — bez tohoto stampneme timestamp i při odmítnuté auth a
    /// dalších 5 min nic neupozorníme i když user nakonec auth povolí.
    @discardableResult
    static func postAsync(title: String, body: String, sound: Bool = true) async -> Bool {
        await ensureAuth()
        guard authGranted else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(req)
            return true
        } catch {
            return false
        }
    }
}
