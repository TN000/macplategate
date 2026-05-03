import Foundation
import CryptoKit

/// HTTP Digest Access Authentication (RFC 2617 / RFC 7616) — pure helper.
/// Žádný network ani state — testovatelné offline. Volá se z RTSPClient
/// pro buildování `Authorization: Digest ...` headeru po 401 challenge.
///
/// Podporované algorithm: MD5, MD5-sess, SHA-256, SHA-256-sess. Default MD5
/// (RFC 2617 backwards-compat) když challenge neobsahuje `algorithm=`.
///
/// `qop` je optional — legacy RFC 2069 challenges (před RFC 2617) qop nepoužívají,
/// response computation se redukuje na `KD(HA1, "nonce:HA2")`. Při qop=auth
/// (RFC 2617+) se přidá `nc:cnonce:qop` do KD inputu a request musí klient
/// vrátit qop, nc, cnonce v Authorization headeru.
enum DigestAuth {
    enum Algorithm: String {
        case md5 = "MD5"
        case md5sess = "MD5-sess"
        case sha256 = "SHA-256"
        case sha256sess = "SHA-256-sess"

        /// Hash function dle algoritmu. Vrací lowercase hex.
        func hash(_ s: String) -> String {
            switch self {
            case .md5, .md5sess:
                let digest = Insecure.MD5.hash(data: Data(s.utf8))
                return digest.map { String(format: "%02x", $0) }.joined()
            case .sha256, .sha256sess:
                let digest = SHA256.hash(data: Data(s.utf8))
                return digest.map { String(format: "%02x", $0) }.joined()
            }
        }

        /// Session-based variants přidávají druhý hash kolem HA1 (s nonce + cnonce).
        var isSessionVariant: Bool {
            self == .md5sess || self == .sha256sess
        }
    }

    struct Challenge: Equatable {
        let realm: String
        let nonce: String
        /// nil = legacy RFC 2069 challenge bez qop. Klient vyrobí response bez nc/cnonce/qop.
        let qop: String?
        let opaque: String?
        let algorithm: Algorithm
    }

    // MARK: - Parser

    /// Parse `WWW-Authenticate` header value. Akceptuje single Digest scheme
    /// nebo multi-scheme (`Digest realm="X", Basic realm="Y"`) — vybere první Digest.
    /// Quoted-aware: `qop="auth,auth-int"` má čárku uvnitř quoted value, naive split selže.
    static func parseChallenge(_ headerValue: String) -> Challenge? {
        // Find "Digest" scheme prefix (case-insensitive)
        let scanner = Scanner(string: headerValue)
        scanner.charactersToBeSkipped = .whitespaces
        guard let scheme = scanner.scanUpToCharacters(from: .whitespaces),
              scheme.lowercased() == "digest" else {
            // Multi-scheme fallback — find "Digest" anywhere
            guard let digestRange = headerValue.range(of: "Digest", options: [.caseInsensitive]) else {
                return nil
            }
            let body = String(headerValue[digestRange.upperBound...])
            return parseDigestBody(body)
        }
        let body = headerValue[scanner.currentIndex...]
        return parseDigestBody(String(body))
    }

    /// Parse comma-separated `key=value` pairs uvnitř Digest scheme.
    /// State machine respektuje quoted strings — čárka v `qop="auth,auth-int"` zůstane.
    private static func parseDigestBody(_ body: String) -> Challenge? {
        var fields: [String: String] = [:]
        let chars = Array(body)
        var idx = 0
        let n = chars.count

        func skipWhitespaceCommas() {
            while idx < n, chars[idx] == "," || chars[idx].isWhitespace { idx += 1 }
        }

        while idx < n {
            skipWhitespaceCommas()
            guard idx < n else { break }
            // Read key (až do '=')
            let keyStart = idx
            while idx < n, chars[idx] != "=" { idx += 1 }
            guard idx < n else { break }
            let key = String(chars[keyStart..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            idx += 1  // skip '='
            // Value — quoted nebo bare
            var value = ""
            if idx < n, chars[idx] == "\"" {
                idx += 1  // skip opening quote
                let valStart = idx
                while idx < n, chars[idx] != "\"" {
                    // Backslash escape — RFC 7235 dovoluje \" uvnitř quoted-string
                    if chars[idx] == "\\", idx + 1 < n {
                        idx += 2
                    } else {
                        idx += 1
                    }
                }
                value = String(chars[valStart..<idx])
                if idx < n { idx += 1 }  // skip closing quote
            } else {
                let valStart = idx
                while idx < n, chars[idx] != "," { idx += 1 }
                value = String(chars[valStart..<idx]).trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty {
                fields[key] = value
            }
        }

        guard let realm = fields["realm"], let nonce = fields["nonce"] else { return nil }

        let algorithm: Algorithm = {
            guard let alg = fields["algorithm"]?.uppercased() else { return .md5 }  // RFC 2617 default
            // **Pragmatic prefer-MD5:** VIGI C250 firmware advertises
            // `algorithm=SHA-256` ALE server-side response check skutečně
            // očekává MD5 → 401 loop pokud klient pošle SHA-256 hash. MD5
            // funguje spolehlivě napříč firmwary. Default = MD5 i když
            // challenge advertises SHA-256.
            // Multi-algo offer (`SHA-256, MD5`) — preferuj MD5.
            let parts = alg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.contains("MD5") { return .md5 }
            if parts.contains("MD5-SESS") { return .md5sess }
            // Server advertises výhradně sess / SHA varianta — žádné MD5 v offer
            // → use what server explicitly demanded. Single SHA-256 advertised
            // ALE klient přesto MD5 (firmware-bug fallback): use MD5 default.
            // **Tedy** SHA-256 single value jako MD5. Pokud kamera bude
            // skutečně vyžadovat SHA-256, manual config flag může v budoucnu
            // override.
            if parts.contains("MD5-SESS") || alg.contains("MD5-SESS") { return .md5sess }
            return .md5  // fallback default — VIGI C250 firmware-bug accommodation
        }()

        return Challenge(
            realm: realm,
            nonce: nonce,
            qop: fields["qop"],
            opaque: fields["opaque"],
            algorithm: algorithm
        )
    }

    // MARK: - Response computation

    /// Spočítá `response` field do Authorization headeru per RFC 7616.
    /// Vrátí lowercase hex hash.
    ///
    /// - `nonceCount`: per-client counter, increments per request (1, 2, 3, ...).
    ///   Ignored pokud `challenge.qop == nil` (legacy RFC 2069).
    /// - `cnonce`: client-generated random hex string. Ignored pokud qop nil.
    static func computeResponse(challenge: Challenge,
                                username: String,
                                password: String,
                                method: String,
                                uri: String,
                                nonceCount: Int = 1,
                                cnonce: String) -> String {
        let alg = challenge.algorithm
        // HA1 base = H(username:realm:password)
        var ha1 = alg.hash("\(username):\(challenge.realm):\(password)")
        if alg.isSessionVariant {
            // *-sess: HA1 = H(H(user:realm:pass):nonce:cnonce)
            ha1 = alg.hash("\(ha1):\(challenge.nonce):\(cnonce)")
        }
        // HA2 = H(method:uri) — `auth` qop nebo žádný qop. (auth-int by include body hash, neimplementujeme.)
        let ha2 = alg.hash("\(method):\(uri)")

        if let qop = challenge.qop {
            // qop=auth (preferovaná RFC 7616 cesta): KD(HA1, nonce:nc:cnonce:qop:HA2)
            let qopValue = qopPickAuth(qop)
            let nc = String(format: "%08x", nonceCount)
            return alg.hash("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qopValue):\(ha2)")
        } else {
            // Legacy RFC 2069: KD(HA1, nonce:HA2). Bez nc/cnonce/qop.
            return alg.hash("\(ha1):\(challenge.nonce):\(ha2)")
        }
    }

    /// Vrací string co se má vyplnit do `qop=` pole Authorization headeru.
    /// Pokud server nabídne `auth,auth-int`, vybereme `auth` (auth-int neimplementujeme).
    static func qopPickAuth(_ serverQop: String) -> String {
        let parts = serverQop.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        if parts.contains("auth") { return "auth" }
        // Edge: server nabízí jen auth-int — pošleme `auth` stejně, server pak respond 401
        // a pipeline skončí. Lépe než crash.
        return "auth"
    }

    /// Compose celý `Authorization: Digest ...` header value.
    ///
    /// **VIGI C250 firmware compat:** některé firmware revisi mají extrémně
    /// přísný Authorization parser — algorithm= ani opaque= v response způsobí
    /// 401 (i když oba jsou per RFC 7616 SHOULD-echo). Default jen username,
    /// realm, nonce, uri, response + qop/nc/cnonce když challenge měla qop.
    /// Algorithm + opaque echo je **opt-in** přes `echoAlgorithmOpaque: true`.
    static func buildAuthorizationHeader(challenge: Challenge,
                                          username: String,
                                          password: String,
                                          method: String,
                                          uri: String,
                                          nonceCount: Int = 1,
                                          cnonce: String,
                                          echoAlgorithmOpaque: Bool = false) -> String {
        let response = computeResponse(challenge: challenge, username: username, password: password,
                                       method: method, uri: uri,
                                       nonceCount: nonceCount, cnonce: cnonce)
        var parts = [
            "username=\"\(username)\"",
            "realm=\"\(challenge.realm)\"",
            "nonce=\"\(challenge.nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\"",
        ]
        if let qop = challenge.qop {
            let nc = String(format: "%08x", nonceCount)
            parts.append("qop=\(qopPickAuth(qop))")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        if echoAlgorithmOpaque {
            switch challenge.algorithm {
            case .md5sess: parts.append("algorithm=MD5-sess")
            case .sha256: parts.append("algorithm=SHA-256")
            case .sha256sess: parts.append("algorithm=SHA-256-sess")
            case .md5: break  // default, omit
            }
            if let opaque = challenge.opaque {
                parts.append("opaque=\"\(opaque)\"")
            }
        }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// Vyrobí náhodný cnonce — 16 hex chars (64-bit randomness).
    static func generateCnonce() -> String {
        let lo = UInt32.random(in: 0...UInt32.max)
        let hi = UInt32.random(in: 0...UInt32.max)
        return String(format: "%08x%08x", hi, lo)
    }
}
