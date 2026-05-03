import Foundation
import Network
import CryptoKit

// MARK: - Gate action API (Shelly Pro 1 RPC scenario routing)

/// Sémantická akce pro ovládání závory přes Shelly Pro 1 (gen2 RPC).
/// Pipeline / UI / web-API volá konkrétní akci, ne raw URL — překlad na
/// HTTP volání drží `WebhookClient.buildShellyURL`. Tím se vyhneme tomu,
/// aby admin musel ručně skládat `?id=0&on=true&toggle_after=...`.
///
/// Mapování na Shelly RPC:
/// - `.openShort` → `Switch.Set?id=0&on=true&toggle_after=<pulseShortSec>`
/// - `.openExtended` → `Switch.Set?id=0&on=true&toggle_after=<pulseExtendedSec>`
/// - `.openHoldStart` → `Switch.Set?id=0&on=true` (bez toggle_after — drží do ručního off / Shelly auto_off failsafe)
/// - `.openHoldBeat` → `Switch.Set?id=0&on=true&toggle_after=<keepAliveBeatSec>` (re-trigger 1 Hz)
/// - `.closeRelease` → `Switch.Set?id=0&on=false`
enum GateAction: String, Sendable, Equatable, Codable {
    case openShort
    case openExtended
    case openHoldStart
    case openHoldBeat
    case closeRelease

    /// Krátký tag pro audit log + plate key v rate-limit dictu.
    var auditTag: String { rawValue }
}

/// Tunable parametry pro `GateAction` → URL builder. Hodnoty čte
/// `WebhookClient.fireGateAction` z aktuální config snapshot (typicky
/// kopie z `AppState`).
struct GateActionConfig: Sendable, Equatable {
    var pulseShortSec: Double = 1.0
    var pulseExtendedSec: Double = 20.0
    var keepAliveBeatSec: Double = 2.0

    static let defaults = GateActionConfig()
}

// MARK: - Public API result type

/// Výsledek webhook fire pokusu. Caller rozhoduje, zda na úspěch
/// označit "gate opened" (banner) — banner zasvítí JEN při `.success`.
enum WebhookResult: Equatable {
    case success(httpStatus: Int)
    case rejectedBySSRF(reason: String)
    case networkError(description: String)
    case rateLimited
    case httpError(status: Int)
    /// Klient zakázal redirect (302/3xx). URLSessionDelegate.willPerformHTTPRedirection
    /// vrátil nil — request končí jako success na serverové straně, ale klient
    /// to považuje za failure protože nedoručil request na finální URL.
    case redirectBlocked(toLocation: String)

    static func == (lhs: WebhookResult, rhs: WebhookResult) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)): return a == b
        case (.rateLimited, .rateLimited): return true
        case (.httpError(let a), .httpError(let b)): return a == b
        case (.rejectedBySSRF(let a), .rejectedBySSRF(let b)): return a == b
        case (.networkError(let a), .networkError(let b)): return a == b
        case (.redirectBlocked(let a), .redirectBlocked(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - DNS resolver protocol (injectable for tests)

/// Resolver protocol — production wraps `getaddrinfo` v Task.detached, tests
/// inject fixed list. Vrací 4-byte (IPv4) nebo 16-byte (IPv6) `Data`.
protocol HostResolverBackend: Sendable {
    func resolve(_ host: String) async throws -> [Data]
}

/// Production resolver — `getaddrinfo` na background queue, off MainActor.
struct SystemHostResolver: HostResolverBackend {
    func resolve(_ host: String) async throws -> [Data] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC  // both v4 + v6
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>? = nil
            let status = getaddrinfo(host, nil, &hints, &res)
            guard status == 0, let head = res else {
                throw NSError(domain: "DNS", code: Int(status),
                              userInfo: [NSLocalizedDescriptionKey: String(cString: gai_strerror(status))])
            }
            defer { freeaddrinfo(res) }
            var out: [Data] = []
            var cur: UnsafeMutablePointer<addrinfo>? = head
            while let node = cur {
                let p = node.pointee
                if p.ai_family == AF_INET {
                    p.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var addr = sin.pointee.sin_addr
                        let raw = withUnsafeBytes(of: &addr) { Data($0) }
                        out.append(raw)
                    }
                } else if p.ai_family == AF_INET6 {
                    p.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var addr = sin6.pointee.sin6_addr
                        let raw = withUnsafeBytes(of: &addr) { Data($0) }
                        out.append(raw)
                    }
                }
                cur = p.ai_next
            }
            return out
        }.value
    }
}

// MARK: - Validator (IP literal first, DNS as fallback)

/// SSRF guard. Threat model: LAN deployment, webhook URL editovaná adminem.
/// Neblokujeme RFC1918 (Shelly žije v 192.168/10.0/172.16) — jen reálně
/// dangerous bloky: loopback, link-local + AWS metadata, multicast, "this network".
///
/// **Best-effort DNS-resolved SSRF block:** URLSession re-resolve když request
/// fire — short window pro DNS rebinding zůstává. Acceptable pro LAN-only
/// deployment scope (V1). Future V2: pin resolved IP do request.
enum WebhookValidator {
    enum CheckResult {
        case allow
        case rejected(reason: String)
    }

    /// IP literal → validate proti blocklist (skip DNS, literál neznamená
    /// rebinding risk). Hostname → DNS resolve → validate všechny vrácené IP.
    static func checkHost(_ host: String, resolver: HostResolverBackend) async -> CheckResult {
        let stripped = host.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        // 1) IPv4 literal
        if let ip4 = parseIPv4(stripped) {
            return isReservedIPv4(ip4)
                ? .rejected(reason: "IPv4 literal in reserved range: \(stripped)")
                : .allow
        }
        // 2) IPv6 literal
        if let ip6 = parseIPv6(stripped) {
            return isReservedIPv6(ip6)
                ? .rejected(reason: "IPv6 literal in reserved range: \(stripped)")
                : .allow
        }
        // 3) Special hostnames
        if stripped.lowercased() == "localhost" {
            return .rejected(reason: "localhost hostname")
        }
        // 4) Hostname → DNS resolve
        let resolved: [Data]
        do {
            resolved = try await resolver.resolve(stripped)
        } catch {
            return .rejected(reason: "DNS resolve failed: \(error.localizedDescription)")
        }
        if resolved.isEmpty {
            return .rejected(reason: "DNS resolved to no addresses")
        }
        for addr in resolved {
            if addr.count == 4 {
                let ip4 = (UInt8(addr[0]), UInt8(addr[1]), UInt8(addr[2]), UInt8(addr[3]))
                if isReservedIPv4(ip4) {
                    return .rejected(reason: "DNS resolved to reserved IPv4 \(formatIPv4(ip4))")
                }
            } else if addr.count == 16 {
                let bytes = [UInt8](addr)
                if isReservedIPv6(bytes) {
                    return .rejected(reason: "DNS resolved to reserved IPv6")
                }
            }
        }
        return .allow
    }

    // MARK: IP parsing

    static func parseIPv4(_ s: String) -> (UInt8, UInt8, UInt8, UInt8)? {
        var addr = in_addr()
        let result = s.withCString { inet_pton(AF_INET, $0, &addr) }
        guard result == 1 else { return nil }
        let raw = withUnsafeBytes(of: &addr) { Array($0) }
        guard raw.count >= 4 else { return nil }
        return (raw[0], raw[1], raw[2], raw[3])
    }

    static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        let result = s.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        return bytes.count == 16 ? bytes : nil
    }

    static func formatIPv4(_ ip: (UInt8, UInt8, UInt8, UInt8)) -> String {
        "\(ip.0).\(ip.1).\(ip.2).\(ip.3)"
    }

    // MARK: Block list rules

    /// Blokované IPv4 ranges:
    /// - 0.0.0.0/8 (this network, "wildcard")
    /// - 127.0.0.0/8 (loopback)
    /// - 169.254.0.0/16 (link-local + AWS/GCP/Azure metadata 169.254.169.254)
    /// - 224.0.0.0/4 (multicast)
    /// - 240.0.0.0/4 (reserved future use)
    /// - 255.255.255.255 (broadcast)
    /// **NEbloká** RFC1918 (10/8, 172.16/12, 192.168/16) — Shelly + IoT žijí v LAN.
    static func isReservedIPv4(_ ip: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        let a = ip.0
        if a == 0 { return true }
        if a == 127 { return true }
        if a == 169 && ip.1 == 254 { return true }
        if a >= 224 && a <= 239 { return true }  // multicast
        if a >= 240 { return true }  // reserved + broadcast
        return false
    }

    /// Blokované IPv6 ranges:
    /// - ::1 (loopback)
    /// - fe80::/10 (link-local)
    /// - fc00::/7 (unique local — debatable, blokujeme)
    /// - ff00::/8 (multicast)
    /// - :: (wildcard)
    static func isReservedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // ::
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        // ::1
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        // fe80::/10
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return true }
        // fc00::/7 (unique local)
        if (bytes[0] & 0xFE) == 0xFC { return true }
        // ff00::/8
        if bytes[0] == 0xFF { return true }
        return false
    }
}

// MARK: - URLSession delegate (V1 strict redirect rejection)

/// Blokuje VŠECHNY HTTP redirecty. SSRF DNS check běží PŘED URLSession requestem;
/// pokud server vrátí 302 Location: http://127.0.0.1, URLSession by ji default
/// follownul a obešel SSRF gate. V1: completionHandler(nil) → URLSession dropne
/// redirect a doručí 302 status klientovi.
///
/// V2 deferred: re-validate Location host přes WebhookValidator.checkHost — víc
/// plumbing v async delegate, Shelly 302 nepoužívá takže není urgent.
/// Stateless delegate — žádný shared mutable state. Caller (fireInternal)
/// rozpozná redirect block z URLError.cancelled kombinovaného s response
/// status 3xx — pokud HTTP response 3xx přijde a downstream task se cancelne,
/// klasifikujeme jako `.redirectBlocked`.
private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let target = request.url?.absoluteString ?? "<unknown>"
        FileHandle.safeStderrWrite(
            "[Webhook] redirect blocked (status \(response.statusCode)) → \(LogSanitizer.sanitizeURL(target))\n".data(using: .utf8)!)
        completionHandler(nil)
    }
}

/// **Manual Digest auth** — Foundation URLSession na macOS spolehlivě
/// **nezavolá** `didReceive challenge` callback pro Shelly Pro 1, protože
/// server po 401 odpovědi posílá `Connection: close` a URLSession ukončí
/// task bez retry. Implementujeme RFC 7616 Digest auth ručně:
///
/// 1. Pošli první request bez Authorization header.
/// 2. Server vrátí 401 + `WWW-Authenticate: Digest realm=..., nonce=...,
///    qop=auth, algorithm=SHA-256`.
/// 3. Spočítej `response = H(H(user:realm:password):nonce:nc:cnonce:qop:H(method:uri))`.
/// 4. Retry request s `Authorization: Digest username=...,
///    realm=..., nonce=..., uri=..., qop=auth, nc=00000001, cnonce=...,
///    response=..., algorithm=SHA-256`.
///
/// Podporuje **SHA-256** (Shelly Pro Gen 2 default) i **MD5** (legacy /
/// older firmware). MD5 přes `CryptoKit.Insecure.MD5` (deprecated ale
/// pro Digest interop nutný).
enum WebhookDigestAuth {
    /// Parametry vyextrahované z `WWW-Authenticate: Digest ...` headeru.
    struct ChallengeParams {
        let realm: String
        let nonce: String
        let qop: String?
        let opaque: String?
        let algorithm: String  // "SHA-256" nebo "MD5"
    }

    /// Parse `WWW-Authenticate: Digest qop="auth", realm="X", nonce="Y", ...`.
    /// Vrátí nil pokud header není Digest nebo chybí realm/nonce.
    static func parseChallenge(_ www: String) -> ChallengeParams? {
        let trimmed = www.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("digest") else { return nil }
        let body = String(trimmed.dropFirst("digest".count))
            .trimmingCharacters(in: .whitespaces)
        // Naivní parser: split podle čárek, každý kus na key=value.
        // Hodnoty mohou (ale nemusí) být v uvozovkách. Robustní pro Shelly,
        // RFC 7616 dovoluje víc edge cases ale Shelly drží jednoduchý formát.
        var dict: [String: String] = [:]
        var pos = body.startIndex
        while pos < body.endIndex {
            // Skip whitespace + comma
            while pos < body.endIndex, body[pos] == " " || body[pos] == "," { pos = body.index(after: pos) }
            guard pos < body.endIndex else { break }
            // Read key
            guard let eqIdx = body[pos...].firstIndex(of: "=") else { break }
            let key = String(body[pos..<eqIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            pos = body.index(after: eqIdx)
            // Skip whitespace
            while pos < body.endIndex, body[pos] == " " { pos = body.index(after: pos) }
            // Read value (quoted nebo token)
            var value = ""
            if pos < body.endIndex, body[pos] == "\"" {
                pos = body.index(after: pos)
                while pos < body.endIndex, body[pos] != "\"" {
                    value.append(body[pos])
                    pos = body.index(after: pos)
                }
                if pos < body.endIndex { pos = body.index(after: pos) }
            } else {
                while pos < body.endIndex, body[pos] != "," {
                    value.append(body[pos])
                    pos = body.index(after: pos)
                }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            dict[key] = value
        }
        guard let realm = dict["realm"], let nonce = dict["nonce"] else { return nil }
        let algo = dict["algorithm"]?.uppercased() ?? "MD5"
        return ChallengeParams(
            realm: realm, nonce: nonce,
            qop: dict["qop"], opaque: dict["opaque"], algorithm: algo
        )
    }

    /// Výpočet `Authorization: Digest ...` hodnoty pro daný request.
    /// `uri` je request-URI (path + ?query). `method` typicky "GET".
    static func authorizationHeader(challenge: ChallengeParams,
                                     method: String, uri: String,
                                     user: String, password: String) -> String {
        let hash: (String) -> String
        if challenge.algorithm.contains("SHA-256") {
            hash = { sha256Hex($0) }
        } else {
            hash = { md5Hex($0) }
        }
        let ha1 = hash("\(user):\(challenge.realm):\(password)")
        let ha2 = hash("\(method):\(uri)")

        let cnonce = randomCnonce()
        let nc = "00000001"
        let qop = challenge.qop?.lowercased().contains("auth") == true ? "auth" : nil

        let response: String
        if let qop = qop {
            response = hash("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = hash("\(ha1):\(challenge.nonce):\(ha2)")
        }

        var parts = [
            "username=\"\(user)\"",
            "realm=\"\(challenge.realm)\"",
            "nonce=\"\(challenge.nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\"",
            "algorithm=\(challenge.algorithm)"
        ]
        if let qop = qop {
            parts.append("qop=\(qop)")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(cnonce)\"")
        }
        if let opaque = challenge.opaque, !opaque.isEmpty {
            parts.append("opaque=\"\(opaque)\"")
        }
        return "Digest " + parts.joined(separator: ", ")
    }

    private static func sha256Hex(_ s: String) -> String {
        let h = SHA256.hash(data: Data(s.utf8))
        return h.map { String(format: "%02x", $0) }.joined()
    }
    private static func md5Hex(_ s: String) -> String {
        let h = Insecure.MD5.hash(data: Data(s.utf8))
        return h.map { String(format: "%02x", $0) }.joined()
    }
    private static func randomCnonce() -> String {
        let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-task delegate — handluje **HTTP auth challenge** (Basic / Digest /
/// default) a redirect blocking. URLSession by sice user/password z URL
/// userinfo měla automaticky odbavit, ale **Digest auth challenge** s
/// `Foundation.URLSession` na macOS spolehlivě nefunguje bez explicit
/// `didReceive challenge` delegate handleru. Bez něj Shelly Pro 1 (Digest
/// SHA-256) vrací 401 i s URL embed creds. Tenhle delegate se předává
/// přes `URLSession.data(for:delegate:)` per-task, nemění shared session
/// state (creds drží jen po dobu jednoho fire).
private final class AuthAndRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let user: String
    let password: String

    init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        // Server TLS (HTTPS) — pass through, ne naše věc.
        if method == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Auth challenge (Basic / Digest / default). Pošli URLCredential
        // pokud máme creds. previousFailureCount=1+ = už jsme to zkusili a
        // server stále odmítá → bail s default handling (URLSession vrátí 401).
        if method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodDefault {
            if challenge.previousFailureCount == 0, !user.isEmpty {
                completionHandler(.useCredential,
                    URLCredential(user: user, password: password, persistence: .none))
                return
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    /// Per-task delegate **nahrazuje** session-level RedirectBlockingDelegate
    /// pro tento request, takže redirect blocking musí být i tady.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let target = request.url?.absoluteString ?? "<unknown>"
        FileHandle.safeStderrWrite(
            "[Webhook] redirect blocked (status \(response.statusCode)) → \(LogSanitizer.sanitizeURL(target))\n".data(using: .utf8)!)
        completionHandler(nil)
    }
}

// MARK: - WebhookClient (async API + legacy fire-and-forget compat)

/// Webhook fire-and-forget GET klient pro Shelly Pro 1 a podobné HTTP relé.
/// Nový async API (`fireOnce`, `fireWithRetries`) vrací `WebhookResult` — caller
/// pak rozhoduje banner / UI feedback. Legacy `fire(...)` shim zachovává
/// existing fire-and-forget behavior pro UI cesty které explicit success
/// nepotřebují.
@MainActor
final class WebhookClient: ObservableObject {
    static let shared = WebhookClient()

    @Published var lastFired: (url: String, plate: String, ts: Date, status: Int)? = nil

    /// Per-(url, plate) cooldown. Rate limit gates **nové duplicitní** events,
    /// ale retry stejného eventu obejde limit přes `attempt > 1`.
    private var lastFireTime: [String: Date] = [:]  // key = "url|plate"
    private static let minIntervalSec: TimeInterval = 2.0

    /// Runtime-nastavitelné z AppState (Settings → Webhook).
    var maxRetryCount: Int = 3
    var timeoutSec: TimeInterval = 2.0
    private static let retryBaseDelay: TimeInterval = 0.5  // 0.5s, 1s, 2s

    /// Resolver — injectable pro testy.
    var resolver: HostResolverBackend = SystemHostResolver()

    init(resolver: HostResolverBackend = SystemHostResolver()) {
        self.resolver = resolver
    }

    /// Sessions — production vs no-redirect. Lazily inicialiualizujeme.
    /// Per-request timeout je dán fireInternal `perAttemptTimeout` přes
    /// `URLRequest.timeoutInterval`. Session-level timeout `timeoutIntervalForRequest`
    /// musí být **alespoň tak vysoký**, jinak override request setting nelze.
    /// Default 30 s = upper bound i pro nejdelší retry; per-request 0.5–2 s
    /// klamá kratší.
    private lazy var redirectDelegate = RedirectBlockingDelegate()
    private lazy var noRedirectSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30.0
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    /// Inflight Swift Task handles ze `fire()` legacy shim. cancelAll() je
    /// canceluje + URLSession.getAllTasks invaliduje pending HTTP requesty.
    /// Task se sám odstraní z pole po dokončení (defer block) — pole je
    /// vždy aktuální seznam **opravdu** běžících tasků, žádný unbounded growth.
    fileprivate struct InflightTask: Identifiable {
        let id: UUID
        let task: Task<Void, Never>
    }
    fileprivate var inflightTasks: [InflightTask] = []

    // MARK: - Async API (rev 6)

    /// First-attempt only, krátký timeout. Pro UI cesty kde uživatel čeká.
    /// Žádný retry — caller dostane výsledek do `timeout`.
    func fireOnce(url rawURL: String, plate: String, camera: String,
                  vehicleType: String? = nil, vehicleColor: String? = nil,
                  eventId: String,
                  timeout: TimeInterval = 2.0) async -> WebhookResult {
        return await fireInternal(rawURL: rawURL, plate: plate, camera: camera,
                                  vehicleType: vehicleType, vehicleColor: vehicleColor,
                                  eventId: eventId, attempt: 1, maxAttempts: 1,
                                  perAttemptTimeout: timeout)
    }

    /// Full retry policy (3× exp backoff). Background ALPR commit cesta.
    /// Caller obvykle fire-and-forget: `Task { await fireWithRetries(...) }`.
    func fireWithRetries(url rawURL: String, plate: String, camera: String,
                         vehicleType: String? = nil, vehicleColor: String? = nil,
                         eventId: String) async -> WebhookResult {
        let maxAttempts = max(1, maxRetryCount + 1)
        var lastResult: WebhookResult = .networkError(description: "no attempts")
        for attempt in 1...maxAttempts {
            // Cooperative cancellation — cancelAll() Task.cancel() signál
            // překlopí Task.isCancelled na true mezi retries, předčasné return.
            if Task.isCancelled {
                return .networkError(description: "cancelled by client")
            }
            let result = await fireInternal(rawURL: rawURL, plate: plate, camera: camera,
                                            vehicleType: vehicleType, vehicleColor: vehicleColor,
                                            eventId: eventId, attempt: attempt,
                                            maxAttempts: maxAttempts,
                                            perAttemptTimeout: timeoutSec)
            // Success / SSRF reject / rate limited — žádný retry.
            switch result {
            case .success, .rejectedBySSRF, .rateLimited:
                return result
            default:
                lastResult = result
                if attempt < maxAttempts {
                    let delay = Self.retryBaseDelay * pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled {
                        return .networkError(description: "cancelled by client")
                    }
                }
            }
        }
        // Fired all attempts, all failed.
        ErrorNotifier.fire(.webhookFailure,
                           title: "Webhook selhal",
                           body: "Relé nereagovalo po \(maxAttempts) pokusech. Závora se neotevře.")
        return lastResult
    }

    private func fireInternal(rawURL: String, plate: String, camera: String,
                              vehicleType: String?, vehicleColor: String?,
                              eventId: String, attempt: Int, maxAttempts: Int,
                              perAttemptTimeout: TimeInterval) async -> WebhookResult {
        // Build URL with vehicle metadata params.
        var urlString = rawURL
        if vehicleType != nil || vehicleColor != nil {
            var params: [String] = []
            if let vt = vehicleType, !rawURL.contains("vehicle_type=") {
                params.append("vehicle_type=\(vt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vt)")
            }
            if let vc = vehicleColor, !rawURL.contains("vehicle_color=") {
                params.append("vehicle_color=\(vc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vc)")
            }
            if !params.isEmpty {
                let sep = rawURL.contains("?") ? "&" : "?"
                urlString = rawURL + sep + params.joined(separator: "&")
            }
        }
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            logLine("[Webhook] rejected non-http(s) URL: \(LogSanitizer.sanitizeURL(urlString))")
            return .rejectedBySSRF(reason: "non-http(s) scheme")
        }

        // **Rate limit — split: GATE check before SSRF, TIMESTAMP write after.**
        // (1) GATE check (read-only) musí běžet PŘED async DNS/SSRF čekáním;
        //     jinak dva souběžné duplicate eventy projdou oba (první ještě
        //     nestihl zapsat cooldown). Pure read → bezpečné před SSRF.
        // (2) TIMESTAMP write proběhne AŽ PO SSRF úspěchu — `.rejectedBySSRF`
        //     event nesmí zapsat lastFireTime, jinak retry s opraveným URL by
        //     dostal misleading `.rateLimited` místo OK.
        let rateKey: String
        if attempt == 1 {
            let normalizedPlate = plate.uppercased()
            rateKey = "\(urlString)|\(normalizedPlate)"
            if let last = lastFireTime[rateKey],
               Date().timeIntervalSince(last) < Self.minIntervalSec {
                logLine("[Webhook] rate-limited (\(plate))")
                return .rateLimited
            }
        } else {
            rateKey = ""  // retry; nezapisujeme žádný timestamp.
        }

        // SSRF check — IP literal first, DNS as fallback.
        if let host = url.host {
            let check = await WebhookValidator.checkHost(host, resolver: resolver)
            if case .rejected(let reason) = check {
                logLine("[Webhook] SSRF rejected host=\(host): \(reason)")
                return .rejectedBySSRF(reason: reason)
            }
        } else {
            return .rejectedBySSRF(reason: "no host in URL")
        }

        // SSRF passed — teď zapíšeme cooldown timestamp + GC dictu.
        if attempt == 1, !rateKey.isEmpty {
            let now = Date()
            lastFireTime[rateKey] = now
            if lastFireTime.count > 100 {
                let cutoff = now.addingTimeInterval(-60)
                lastFireTime = lastFireTime.filter { $0.value > cutoff }
            }
        }

        // **Auth handling:** pokud URL má embedded userinfo (`http://user:pass@host`),
        // extract a strip pre-flight. Foundation URLSession Digest challenge
        // bez explicit delegate spolehlivě nefunguje na macOS — proto per-task
        // `AuthAndRedirectDelegate` který odpoví URLCredential při 401.
        var requestURL = url
        var authUser = ""
        var authPassword = ""
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let u = components.user, !u.isEmpty {
            authUser = u.removingPercentEncoding ?? u
            authPassword = (components.password ?? "").removingPercentEncoding ?? components.password ?? ""
            components.user = nil
            components.password = nil
            if let cleanURL = components.url { requestURL = cleanURL }
        }

        // HTTP request
        var req = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: perAttemptTimeout)
        req.setValue("SPZ/1.0 (\(camera))", forHTTPHeaderField: "User-Agent")

        do {
            // **Auth flow:** vždy nejprve pošli request bez Authorization
            // headeru. Pokud máme creds a server odpoví 401 s Digest
            // WWW-Authenticate, spočti response sami a retry. URLSession
            // auto-handling Digest challenge na macOS spolehlivě nefunguje
            // (Shelly Pro 1 posílá Connection: close po 401 → URLSession
            // task ukončí bez retry). Manuální cesta je deterministická.
            var (_, response): (Data, URLResponse) = try await noRedirectSession.data(for: req)
            var httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1

            if httpStatus == 401, !authUser.isEmpty,
               let httpResp = response as? HTTPURLResponse,
               let www = (httpResp.value(forHTTPHeaderField: "WWW-Authenticate")
                         ?? httpResp.value(forHTTPHeaderField: "Www-Authenticate")),
               let challenge = WebhookDigestAuth.parseChallenge(www) {
                let pathAndQuery: String = {
                    var p = requestURL.path
                    if p.isEmpty { p = "/" }
                    if let q = requestURL.query, !q.isEmpty { p += "?\(q)" }
                    return p
                }()
                let authValue = WebhookDigestAuth.authorizationHeader(
                    challenge: challenge, method: "GET", uri: pathAndQuery,
                    user: authUser, password: authPassword)
                var authReq = req
                authReq.setValue(authValue, forHTTPHeaderField: "Authorization")
                let (_, resp2) = try await noRedirectSession.data(for: authReq)
                response = resp2
                httpStatus = (resp2 as? HTTPURLResponse)?.statusCode ?? -1
                logLine("[Webhook] Digest auth retry → \(httpStatus) (realm=\(challenge.realm))")
            }

            if httpStatus >= 200 && httpStatus < 300 {
                lastFired = (urlString, plate, Date(), httpStatus)
                logLine("[Webhook] \(plate) → \(httpStatus) (attempt \(attempt)/\(maxAttempts))")
                ErrorNotifier.clear(.webhookFailure)
                return .success(httpStatus: httpStatus)
            }
            // Redirect blocked: status 3xx + URLSession nedoručilo follow-up
            // (delegate vrátil nil v willPerformHTTPRedirection). Klasifikujeme
            // jako .redirectBlocked, ne generic httpError, abychom v WebServer
            // /api/open-gate cestě mohli vrátit 502 specifický pro redirect.
            if httpStatus >= 300 && httpStatus < 400 {
                logLine("[Webhook] \(plate) redirect blocked status=\(httpStatus) url=\(LogSanitizer.sanitizeURL(urlString))")
                return .redirectBlocked(toLocation: urlString)
            }
            logLine("[Webhook] \(plate) HTTP \(httpStatus) (attempt \(attempt)/\(maxAttempts))")
            return .httpError(status: httpStatus)
        } catch {
            let msg = error.localizedDescription
            logLine("[Webhook] \(plate) network error: \(LogSanitizer.sanitizeURL(msg)) (attempt \(attempt)/\(maxAttempts))")
            return .networkError(description: msg)
        }
    }

    // MARK: - Legacy sync API (backward compat for UI cesty kde explicit success není potřeba)

    /// Fire-and-forget shim — pro UI test buttons + ostatní cesty co nečekají
    /// na 2xx. ALPR + webUI manual gate cesty volají `fireOnce` / `fireWithRetries`
    /// async a respond na výsledek. Tahle vrací true vždy pokud URL projde
    /// preliminary syntax check (rate limit / SSRF / HTTP success se vyhodnotí
    /// asynchronně v background Task).
    @discardableResult
    func fire(url rawURL: String, plate: String, camera: String,
              vehicleType: String? = nil, vehicleColor: String? = nil) -> Bool {
        guard !rawURL.isEmpty, let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            logLine("[Webhook] rejected non-http(s) URL: \(LogSanitizer.sanitizeURL(rawURL))")
            return false
        }
        _ = url  // syntax check only; full validation v fireWithRetries
        let eventId = "LEGACY-\(UUID().uuidString)"
        // **Self-cleaning task:** task po dokončení sám sebe odstraní z
        // inflightTasks (atomic via captured ID), žádný trim threshold není potřeba.
        let taskId = UUID()
        let task = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.inflightTasks.removeAll { $0.id == taskId }
                }
            }
            _ = await self?.fireWithRetries(url: rawURL, plate: plate, camera: camera,
                                            vehicleType: vehicleType, vehicleColor: vehicleColor,
                                            eventId: eventId)
        }
        inflightTasks.append(InflightTask(id: taskId, task: task))
        return true
    }

    // MARK: - Gate action API (scenario routing for Shelly Pro 1)

    /// Postaví URL pro `Switch.Set` z base URL Shelly + `GateAction` semantiky.
    ///
    /// Akceptuje base ve formách:
    /// - `http://192.0.2.163`
    /// - `http://192.0.2.163/`
    /// - `http://192.0.2.163/rpc/Switch.Set`
    /// - `http://admin:pass@192.0.2.163`  (legacy — userinfo už v URL)
    ///
    /// Pokud `user`/`password` non-empty, jsou injektnuti do URL jako userinfo
    /// (`http://user:pass@host/...`) s percent-encoding pro RFC 3986 reserved
    /// chars. URLSession je pak použije pro Basic / Digest 401 challenge.
    ///
    /// Výstup: kompletní GET URL s `?id=0&on=...` query.
    nonisolated static func buildShellyURL(baseURL: String,
                                           user: String = "",
                                           password: String = "",
                                           action: GateAction,
                                           config: GateActionConfig) -> String? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/") { base.removeLast() }
        // Inject user:password@ za scheme:// pokud poskytnuto a URL ho nemá.
        if !user.isEmpty,
           let schemeRange = base.range(of: "://"),
           !base[schemeRange.upperBound...].contains("@") {
            // Allowed sets: userinfo per RFC 3986 (unreserved + pct-encoded + sub-delims + ":").
            // `urlUserAllowed` / `urlPasswordAllowed` z Foundation jsou defenzivní.
            let encUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            let encPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
            let userinfo = encPass.isEmpty ? encUser : "\(encUser):\(encPass)"
            base = String(base[..<schemeRange.upperBound]) + userinfo + "@" + String(base[schemeRange.upperBound...])
        }
        // Pokud base nemá path, přilep `/rpc/Switch.Set`.
        if let url = URL(string: base), (url.path.isEmpty || url.path == "/") {
            base += "/rpc/Switch.Set"
        }
        if let qIdx = base.firstIndex(of: "?") {
            base = String(base[..<qIdx])
        }
        let params: String
        switch action {
        case .openShort:
            params = "id=0&on=true&toggle_after=\(formatSec(config.pulseShortSec))"
        case .openExtended:
            params = "id=0&on=true&toggle_after=\(formatSec(config.pulseExtendedSec))"
        case .openHoldStart:
            params = "id=0&on=true"
        case .openHoldBeat:
            params = "id=0&on=true&toggle_after=\(formatSec(config.keepAliveBeatSec))"
        case .closeRelease:
            params = "id=0&on=false"
        }
        return base + "?" + params
    }

    /// Pošle gate action na Shelly. `eventId` typicky obsahuje action tag pro audit
    /// trail. Caller (UI / pipeline / web API) předává aktuální `GateActionConfig`
    /// snapshot z `AppState` plus auth credentials per device.
    func fireGateAction(_ action: GateAction, baseURL: String,
                        user: String = "", password: String = "",
                        plate: String, camera: String, config: GateActionConfig,
                        eventId: String, timeout: TimeInterval = 2.0) async -> WebhookResult {
        guard let url = Self.buildShellyURL(baseURL: baseURL, user: user,
                                             password: password, action: action,
                                             config: config) else {
            return .rejectedBySSRF(reason: "empty Shelly base URL")
        }
        // Rate-limit klíč obsahuje action tag — `.openHoldBeat` nesmí blokovat
        // následný `.closeRelease` (a vice versa). `MANUAL` plate stačí, beat
        // tasky netvoří unbounded plate-keys.
        let actionPlate = "\(plate)#\(action.auditTag)"
        return await fireOnce(url: url, plate: actionPlate, camera: camera,
                              eventId: eventId, timeout: timeout)
    }

    /// Gate action s retry policy (analog `fireWithRetries`). Pro ALPR commit
    /// cestu — auto už projelo, řidič čeká, jeden flaknutý HTTP pokus by stálo
    /// neotevřenou závoru. Exp backoff 0.5/1/2 s, default 3 retries (configable
    /// přes `maxRetryCount`).
    /// Stop signály bez retry: `.success`, `.rejectedBySSRF`, `.rateLimited`.
    func fireGateActionWithRetries(_ action: GateAction, baseURL: String,
                                   user: String = "", password: String = "",
                                   plate: String, camera: String,
                                   config: GateActionConfig,
                                   eventId: String) async -> WebhookResult {
        let maxAttempts = max(1, maxRetryCount + 1)
        var lastResult: WebhookResult = .networkError(description: "no attempts")
        for attempt in 1...maxAttempts {
            if Task.isCancelled {
                return .networkError(description: "cancelled by client")
            }
            let result = await fireGateAction(
                action, baseURL: baseURL, user: user, password: password,
                plate: plate, camera: camera, config: config,
                eventId: eventId, timeout: timeoutSec)
            switch result {
            case .success, .rejectedBySSRF, .rateLimited:
                return result
            default:
                lastResult = result
                if attempt < maxAttempts {
                    let delay = Self.retryBaseDelay * pow(2.0, Double(attempt - 1))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled {
                        return .networkError(description: "cancelled by client")
                    }
                }
            }
        }
        ErrorNotifier.fire(.webhookFailure,
                           title: "Webhook selhal",
                           body: "Relé nereagovalo po \(maxAttempts) pokusech. Závora se neotevře.")
        return lastResult
    }

    nonisolated private static func formatSec(_ sec: Double) -> String {
        // Shelly RPC akceptuje float toggle_after, ale pro audit cleanness vracej
        // integer pokud hodnota je celé číslo (1.0 → "1", 2.5 → "2.5").
        if sec.rounded() == sec && sec >= 0 {
            return String(Int(sec))
        }
        return String(format: "%.2f", sec)
    }

    /// Cancel všech in-flight webhook requestů — volej při změně webhookURL
    /// v settingsu nebo při shutdown. Dvojitá cesta:
    ///
    /// 1. **Swift Tasks** uložené v `inflightTasks` — Task.cancel() signalizuje
    ///    `Task.isCancelled` co `fireWithRetries` retry loop respektuje a předčasně
    ///    return-uje `.networkError`. Ne `URLSession.data(for:)` ale meanwhile
    ///    cancellation odstaví retry pokusy.
    /// 2. **URLSession HTTP tasks** přes `getAllTasks { cancel }` — okamžitě
    ///    fláknou network operations s `URLError.cancelled`.
    func cancelAll() {
        for entry in inflightTasks { entry.task.cancel() }
        inflightTasks.removeAll()
        let session = noRedirectSession
        session.getAllTasks { tasks in
            for task in tasks { task.cancel() }
        }
    }

    // MARK: - Helpers

    private func logLine(_ msg: String) {
        FileHandle.safeStderrWrite((msg + "\n").data(using: .utf8)!)
    }
}
