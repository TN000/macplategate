import Foundation

/// Generuje silné heslo pro WebUI Basic Auth — 4 znakové třídy guaranteed
/// (lower, upper, digit, symbol) → projde `WebServer.webUIPasswordRejection`.
/// Vyhýbá se confusing chars (l, I, 1, O, 0) aby user mohl heslo přepsat
/// z generated string bez OCR-style záměn.
///
/// Extracted ze `SettingsView.swift` jako součást big-refactor split (krok #10).
func generateStrongPassword(length: Int) -> String {
    let lower = Array("abcdefghjkmnpqrstuvwxyz")
    let upper = Array("ABCDEFGHJKMNPQRSTUVWXYZ")
    let digits = Array("23456789")
    let symbols = Array("!@#$%^&*-_=+?")
    let allChars = lower + upper + digits + symbols
    let n = max(12, length)
    var pwd: [Character] = []
    if let c = lower.randomElement() { pwd.append(c) }
    if let c = upper.randomElement() { pwd.append(c) }
    if let c = digits.randomElement() { pwd.append(c) }
    if let c = symbols.randomElement() { pwd.append(c) }
    while pwd.count < n {
        if let c = allChars.randomElement() { pwd.append(c) }
    }
    pwd.shuffle()
    return String(pwd)
}
