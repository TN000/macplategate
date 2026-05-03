import Foundation
import Network
import AppKit
import CoreImage

/// Minimální embedded HTTP server pro remote control SPZ.app z prohlížeče
/// na firemní síti. Žádné external dependencies — Network.framework only.
///
/// **Bezpečnost:** Basic Auth (plaintext Base64 přes HTTP). Akceptabilní pro
/// internal LAN s důvěryhodnými klienty. Pro public přístup by musel být HTTPS
/// + self-signed cert (nebo reverse-proxy přes nginx/Caddy s Let's Encrypt).
///
/// **Endpointy:**
/// - `GET /` — HTML UI (1 stránka, polluje /api/status každé 2 s)
/// - `GET /api/status` — JSON: lastDetection + lastGateOpen
/// - `POST /api/open-gate` — fire webhook pro vjezd
/// - `POST /api/add-daily` — přidá denní vjezd do whitelistu (form: plate,label)
@MainActor
final class WebServer {
    static let shared = WebServer()

    private var listener: NWListener?
    private weak var state: AppState?
    private weak var cameras: CameraManager?
    private let queue = DispatchQueue(label: "spz.webserver", qos: .utility)
    private var connectionRegistry: [ObjectIdentifier: NWConnection] = [:]
    /// Počet krátkých retries (3 s interval) při `Address in use`. Po vyčerpání
    /// přepne do `bindRetryLongMode` (60 s interval, unbounded) — port nemusí
    /// být volný do 30 s (long TCP TIME_WAIT, zaseklá předchozí instance,
    /// jiná aplikace drží port).
    /// Per-request scratch — sync route() ho nastaví podle `?action=...` v URL,
    /// async openGateActionAsync ho přečte. WebServer je @MainActor → single-threaded.
    private var pendingOpenGateAction: GateAction = .openShort
    /// Per-request kamera scratch (vjezd / vyjezd) — `?camera=...`. Default vjezd.
    private var pendingOpenGateCamera: String = "vjezd"
    private var bindRetriesLeft: Int = 10
    private var bindRetryLongMode: Bool = false
    private var lastPortAttempted: UInt16 = 0
    /// Stav listeneru — WebServer není ObservableObject (ani by neměl být,
    /// nemá UI state). HealthMonitor čte synchronně přes svůj 2s Timer.
    private(set) var isListening: Bool = false

    /// Basic Auth creds — username hard-coded "admin", heslo z AppState
    /// (`webUIPassword`, user-nastavitelné v Settings).
    /// Per-request lookup přes `state?.webUIPassword`.
    nonisolated static let authUser = "admin"

    /// **WebUI password policy:**
    /// - Min 12 znaků (NIST SP 800-63B aktuální guideline = 8+, my striktnější)
    /// - Alespoň 3 ze 4 znakových tříd: lowercase, uppercase, digits, symbols
    /// - Reject klasické weak passwords (`admin`, `password`, `12345…`,
    ///   `qwerty`, plus opening `Heslo`/`Kameraheslo` substring + známé legacy
    ///   vendor defaults).
    ///
    /// Vrátí `nil` pokud heslo OK, jinak human-readable důvod (CZ).
    /// Volaná z `WebServer.start()` (refuse start) i ze Settings UI live preview
    /// (`SettingsView.networkCard` zobrazí inline error pod password field).
    nonisolated static func webUIPasswordRejection(_ pwd: String) -> String? {
        if pwd.isEmpty { return "Heslo není nastavené." }
        if pwd.count < 12 {
            return "Heslo má jen \(pwd.count) znaků; potřeba alespoň 12."
        }
        let lower = pwd.lowercased()
        let weakSubstrings = ["kameraszm", "kameraheslo", "heslo", "password",
                              "admin", "qwerty", "12345", "00000", "letmein",
                              "spz", "vigi", "tplink"]
        for w in weakSubstrings where lower.contains(w) {
            return "Heslo obsahuje známý slabý vzor (\"\(w)\")."
        }
        var classes = 0
        if pwd.range(of: "[a-z]", options: .regularExpression) != nil { classes += 1 }
        if pwd.range(of: "[A-Z]", options: .regularExpression) != nil { classes += 1 }
        if pwd.range(of: "[0-9]", options: .regularExpression) != nil { classes += 1 }
        if pwd.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil { classes += 1 }
        if classes < 3 {
            return "Heslo má jen \(classes) typů znaků; potřeba alespoň 3 ze 4 (velká písmena, malá, číslice, speciální)."
        }
        return nil
    }

    /// Per-IP failed auth tracking. 5 failed → ban 5 min. Brání brute-force
    /// přes LAN. MainActor-isolated protože `checkAuth` volá z route() která
    /// běží na MainActor skrze handle's Task @MainActor hop.
    private var authFailures: [String: (count: Int, bannedUntil: Date?)] = [:]
    private static let maxFailedAttempts = 5
    private static let banDurationSec: TimeInterval = 300

    func bind(state: AppState) { self.state = state }
    func bindCameras(_ cameras: CameraManager) { self.cameras = cameras }

    /// Spustí HTTPS server. Self-signed cert se při prvním spuštění vygeneruje
    /// přes `openssl` subprocess (CertManager), na dalších launch se reuse.
    /// Pokud cert generování selže (např. /usr/bin/openssl chybí), server
    /// neběží a UI o tom informuje.
    ///
    /// `resetRetries`: true pro explicit user-facing volání (didSet webUIEnabled,
    /// didSet webUIPort) → fresh retry budget 10 krátkých pokusů. false jen z
    /// `scheduleBindRetry` cyklu, aby se counter postupně snížil a přepnul do
    /// long-retry mode bez nekonečné smyčky resetů.
    func start(port: UInt16, resetRetries: Bool = true) {
        stop()
        if resetRetries {
            bindRetriesLeft = 10
            bindRetryLongMode = false
        }
        // WebUI Basic Auth nesmí běžet se slabým heslem — server odmítne start,
        // pokud heslo nesplňuje minimální bezpečnostní kritéria.
        let pwd = state?.webUIPassword ?? ""
        if let issue = Self.webUIPasswordRejection(pwd) {
            log("WebUI start REFUSED — \(issue)")
            ErrorNotifier.fire(.webUIInsecurePassword,
                               title: "WebUI nemá silné heslo",
                               body: "\(issue) Otevři Nastavení → Síť → WebUI heslo a nastav minimálně 12 znaků s alespoň 3 typy (velká, malá, číslice, speciál).")
            return
        }
        guard let identity = CertManager.loadOrGenerateIdentity() else {
            log("TLS identity unavailable — server not started")
            return
        }
        guard let secIdentity = sec_identity_create(identity) else {
            log("sec_identity_create failed")
            return
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        // Minimum TLS 1.2 — starší je nebezpečný; 1.3 je nice-to-have ale
        // některé starší prohlížeče stále preferují 1.2 ServerHello.
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            log("invalid port \(port)")
            return
        }
        lastPortAttempted = port
        do {
            let l = try NWListener(using: params, on: nwPort)
            l.stateUpdateHandler = { [weak self] state in
                // stateUpdateHandler runs on utility queue (nonisolated). Hop to
                // MainActor pro @Published isListening update (HealthMonitor reader).
                switch state {
                case .ready:
                    self?.log("HTTPS listening on port \(port)")
                    Task { @MainActor [weak self] in
                        self?.isListening = true
                        self?.bindRetriesLeft = 10  // reset na další stop/start cycle
                        self?.bindRetryLongMode = false
                    }
                case .failed(let err):
                    self?.log("listener failed: \(err)")
                    Task { @MainActor [weak self] in
                        self?.isListening = false
                        self?.scheduleBindRetry(err: err)
                    }
                case .cancelled:
                    self?.log("listener cancelled")
                    Task { @MainActor [weak self] in self?.isListening = false }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log("start failed: \(error)")
            scheduleBindRetry(err: error)
        }
    }

    /// Retry bind po výpadku. Dvoufázová strategie:
    ///
    /// 1. **Short mode** (první ~30 s): 10 pokusů po 3 s — pokrývá typický TCP
    ///    TIME_WAIT po restartu předchozího SPZ instance / LaunchAgent rebootu.
    /// 2. **Long mode** (aktivovaný po vyčerpání krátkých pokusů): nekonečně
    ///    retry každých 60 s, dokud port neuvolní (zaseklá app, jiný proces).
    ///    Reset jen při explicit user-facing `start()` (webUIEnabled/webUIPort
    ///    didSet) nebo úspěšném `.ready` listener stavu.
    ///
    /// Dřív po exhausted 10 pokusech WebServer zůstal natrvalo off a user musel
    /// toggleovat v UI; `isListening=false` v HealthMonitor → "zapnuto ale
    /// neposlouchá" i když port byl už 5 min volný.
    private func scheduleBindRetry(err: Error) {
        let delay: TimeInterval
        let label: String
        if bindRetriesLeft > 0 {
            bindRetriesLeft -= 1
            delay = 3.0
            label = "\(bindRetriesLeft) short remaining"
        } else {
            if !bindRetryLongMode {
                bindRetryLongMode = true
                log("short retries exhausted — switching to long mode (60s interval, unbounded)")
            }
            delay = 60.0
            label = "long mode"
        }
        let port = lastPortAttempted
        log("bind retry in \(Int(delay))s (\(label)) after err: \(err)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.listener == nil || self.isListening == false,
                  let appState = self.state, appState.webUIEnabled,
                  port == UInt16(appState.webUIPort) else { return }
            self.listener?.cancel()
            self.listener = nil
            // Nereset counter — retry cyklus pokračuje do short/long transition.
            self.start(port: port, resetRetries: false)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connectionRegistry.values { conn.cancel() }
        connectionRegistry.removeAll()
    }

    // MARK: - Connection handling

    nonisolated private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        let connId = ObjectIdentifier(conn)
        // Extract client IP z NWConnection.endpoint pro rate limit + CIDR whitelist.
        let clientIP = Self.extractClientIP(from: conn)
        Task { @MainActor [weak self] in self?.connectionRegistry[connId] = conn }
        // Recursive receive loop do `\r\n\r\n` + Content-Length bytes, max 64 KB
        // celkem. Chrání POST /api/add-daily proti truncated body (single receive
        // call předpokládá celý request v jednom TCP chunk, což platí jen pro
        // malé LAN requesty).
        receiveRequest(conn, connId: connId, clientIP: clientIP, buffer: Data())
    }

    /// Rekurzivně agreguje TCP chunks dokud nemá celý HTTP request (headers
    /// ukončené `\r\n\r\n` + body of Content-Length bytes). Max buffer 64 KB =
    /// hard DoS guard. Po úspěchu parse + response + close.
    nonisolated private func receiveRequest(_ conn: NWConnection, connId: ObjectIdentifier,
                                            clientIP: String, buffer: Data) {
        let maxRequestBytes = 64 * 1024
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: maxRequestBytes - buffer.count) { [weak self] data, _, isComplete, err in
            guard let self else { conn.cancel(); return }
            guard err == nil else {
                conn.cancel()
                Task { @MainActor [weak self] in self?.connectionRegistry.removeValue(forKey: connId) }
                return
            }
            var buf = buffer
            if let chunk = data { buf.append(chunk) }

            // Zkus najít konec headerů "\r\n\r\n" v buffered datech.
            let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
            guard let headerEnd = buf.range(of: headerTerminator) else {
                // Zatím nedošel celý header — pokud buffer plný nebo stream
                // uzavřen bez `\r\n\r\n`, bail jako malformed.
                if isComplete || buf.count >= maxRequestBytes {
                    conn.cancel()
                    Task { @MainActor [weak self] in self?.connectionRegistry.removeValue(forKey: connId) }
                    return
                }
                // Ještě čteme — rekurzivní další receive.
                self.receiveRequest(conn, connId: connId, clientIP: clientIP, buffer: buf)
                return
            }

            // Máme headers → parse Content-Length. Pokud body ještě nekompletní,
            // čti dál. String lookup pro max první 16 KB aby se nevykonal scan
            // na gigabyte body (naš max 64 KB).
            let headerData = buf.prefix(headerEnd.upperBound)
            let headerStr = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = Self.parseContentLength(headerStr)
            let bodyStart = headerEnd.upperBound
            let bodyReceived = buf.count - bodyStart
            if contentLength > 0, bodyReceived < contentLength {
                if isComplete || buf.count >= maxRequestBytes {
                    // Connection closed / limit reached před full body → malformed
                    conn.cancel()
                    Task { @MainActor [weak self] in self?.connectionRegistry.removeValue(forKey: connId) }
                    return
                }
                self.receiveRequest(conn, connId: connId, clientIP: clientIP, buffer: buf)
                return
            }

            // Máme complete request — parse + odpověď + close.
            let req = String(data: buf, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                guard let self else { conn.cancel(); return }
                let resp = self.route(request: req, clientIP: clientIP)
                // Async route detection: sync route() vrátil sentinel marker
                // pro `/api/open-gate` — počkáme na skutečnou async webhook fire
                // a HTTP response zvolíme podle WebhookResult. Bez tohoto by
                // banner v webUI lhal (200 OK i při relé timeout).
                if resp == Self.openGateAsyncMarker {
                    let actualResp = await self.openGateActionAsync()
                    conn.send(content: actualResp, completion: .contentProcessed { _ in
                        conn.cancel()
                        Task { @MainActor [weak self] in self?.connectionRegistry.removeValue(forKey: connId) }
                    })
                    return
                }
                conn.send(content: resp, completion: .contentProcessed { _ in
                    conn.cancel()
                    Task { @MainActor [weak self] in self?.connectionRegistry.removeValue(forKey: connId) }
                })
            }
        }
    }

    /// Parse `Content-Length: N` header. Vrací 0 pokud chybí nebo malformed.
    nonisolated private static func parseContentLength(_ header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    /// Extract IPv4/IPv6 string z NWConnection.endpoint. Vrací prázdný string
    /// pokud se nepodařilo (anonymous client, CLI tooly bez source IP atd.).
    nonisolated private static func extractClientIP(from conn: NWConnection) -> String {
        guard case let .hostPort(host, _) = conn.endpoint else { return "" }
        switch host {
        case .ipv4(let addr):
            return "\(addr)"
        case .ipv6(let addr):
            return "\(addr)"
        case .name(let n, _):
            return n
        @unknown default:
            return ""
        }
    }

    // MARK: - Router

    private func route(request: String, clientIP: String) -> Data {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, !firstLine.isEmpty else {
            return Self.httpResponseText(code: 400, body: "Bad Request")
        }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return Self.httpResponseText(code: 400, body: "Bad Request")
        }
        let method = parts[0]
        let rawPath = parts[1]
        // Split path + query — query string je opt-in pro endpoints které ho
        // čekají (`/api/open-gate?action=...`). Bez splitu by route case match
        // failoval na exact path comparison.
        let path: String
        let query: String
        if let q = rawPath.firstIndex(of: "?") {
            path = String(rawPath[..<q])
            query = String(rawPath[rawPath.index(after: q)...])
        } else {
            path = rawPath
            query = ""
        }

        // IP whitelist (CIDR) — pokud `state.webUIAllowedCIDRs` nonempty,
        // ověř že clientIP spadá do některého ranges. Jinak 403.
        // Empty = allow all (legacy default, žádný IP lock).
        if let cidrs = state?.webUIAllowedCIDRs.trimmingCharacters(in: .whitespaces),
           !cidrs.isEmpty {
            if !Self.ipMatchesAnyCIDR(clientIP, cidrs: cidrs) {
                log("IP not in whitelist: \(clientIP)")
                return Self.httpResponseText(code: 403, body: "Forbidden: IP not allowed")
            }
        }

        // Rate limit — per-IP ban po 5 failed auth attempts na 5 min.
        // Brání brute-force `admin:*` přes LAN. Blok aplikujeme PŘED auth check
        // aby ban platil i když útočník zkusí znovu se správným heslem — chceme
        // ho odříznout kompletně. Ban se reset při úspěšném loginu.
        if let state, state.webUIRateLimitEnabled, !clientIP.isEmpty {
            if let entry = authFailures[clientIP], let banUntil = entry.bannedUntil,
               Date() < banUntil {
                return Self.httpResponseText(code: 429, body: "Too Many Requests — banned until \(banUntil)")
            }
        }

        // Basic Auth — všechny endpointy chráněné
        let authHeader = lines.first { $0.lowercased().hasPrefix("authorization:") } ?? ""
        if !checkAuth(header: authHeader) {
            // Record failed attempt + eventual ban
            if !clientIP.isEmpty {
                var entry = authFailures[clientIP] ?? (count: 0, bannedUntil: nil)
                entry.count += 1
                if entry.count >= Self.maxFailedAttempts {
                    entry.bannedUntil = Date().addingTimeInterval(Self.banDurationSec)
                    log("AUTH BAN IP=\(clientIP) for \(Int(Self.banDurationSec))s (\(entry.count) failed attempts)")
                } else {
                    log("auth failed IP=\(clientIP) attempt=\(entry.count)/\(Self.maxFailedAttempts)")
                }
                authFailures[clientIP] = entry
            }
            let s = """
                HTTP/1.1 401 Unauthorized\r
                WWW-Authenticate: Basic realm="SPZ ALPR"\r
                Content-Type: text/plain; charset=utf-8\r
                Content-Length: 14\r
                Connection: close\r
                \r
                Unauthorized\n
                """
            return s.data(using: .utf8) ?? Data()
        }
        // Auth úspěšná — reset failure counter pro tento IP.
        if !clientIP.isEmpty { authFailures.removeValue(forKey: clientIP) }

        // Body extraction (po \r\n\r\n separator)
        let body: String = {
            guard let range = request.range(of: "\r\n\r\n") else { return "" }
            return String(request[range.upperBound...])
        }()

        // CSRF ochrana pro POST endpointy — odmítneme request s Origin/Referer
        // header mimo náš vlastní host. Brání tomu aby jiná stránka, kterou má
        // admin otevřenou v browseru, silently triggerovala gate-open přes cached
        // Basic Auth session. GET endpointy nevyžadují CSRF (read-only).
        if method == "POST" {
            let hostHeader = lines.first { $0.lowercased().hasPrefix("host:") } ?? ""
            let originHeader = lines.first { $0.lowercased().hasPrefix("origin:") } ?? ""
            let refererHeader = lines.first { $0.lowercased().hasPrefix("referer:") } ?? ""
            if !Self.checkSameOrigin(host: hostHeader, origin: originHeader, referer: refererHeader) {
                return Self.httpResponseText(code: 403, body: "CSRF: origin mismatch")
            }
        }

        // Crop image endpoint: /api/crop/<id>.jpg
        if method == "GET" && path.hasPrefix("/api/crop/") {
            return cropImageResponse(path: path)
        }

        switch (method, path) {
        case ("GET", "/"):
            return Self.httpResponseText(code: 200, body: Self.indexHTML, contentType: "text/html; charset=utf-8")
        case ("GET", "/api/status"):
            return Self.httpResponseText(code: 200, body: statusJSON(), contentType: "application/json")
        case ("POST", "/api/open-gate"):
            // Sentinel — async dispatcher v receiveRequest počká na webhook
            // response. Action + camera přes query: `?action=short|extended|
            // hold|release&camera=vjezd|vyjezd`. Default short + vjezd.
            pendingOpenGateAction = parseOpenGateAction(query: query)
            pendingOpenGateCamera = parseOpenGateCamera(query: query)
            return Self.openGateAsyncMarker
        case ("POST", "/api/add-daily"):
            return Self.httpResponseText(code: 200, body: addDailyAction(body: body), contentType: "application/json")
        default:
            return Self.httpResponseText(code: 404, body: "Not Found")
        }
    }

    /// Marker Data který signalizuje connection handleru: tahle route je async,
    /// neposílej tento body, místo toho zavolej openGateActionAsync.
    static let openGateAsyncMarker: Data = Data("__SPZ_ASYNC_OPEN_GATE__".utf8)

    /// Parse `?camera=vjezd|vyjezd` query param. Default `vjezd` (back-compat).
    private func parseOpenGateCamera(query: String) -> String {
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "camera" {
                let raw = (kv[1].removingPercentEncoding ?? kv[1]).lowercased()
                if raw == "vyjezd" || raw == "výjezd" { return "vyjezd" }
                return "vjezd"
            }
        }
        return "vjezd"
    }

    /// Parse `?action=short|extended|hold|release` query param na `GateAction`.
    /// Hold spouští `GateHoldController.start`, release `.stop`. Pokud action
    /// chybí nebo je neznámá, default `.openShort`.
    private func parseOpenGateAction(query: String) -> GateAction {
        var actionStr: String = ""
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "action" {
                actionStr = kv[1].removingPercentEncoding ?? kv[1]
                break
            }
        }
        switch actionStr.lowercased() {
        case "extended", "bus": return .openExtended
        case "hold", "hold-start": return .openHoldStart
        case "release", "close": return .closeRelease
        case "beat": return .openHoldBeat
        default: return .openShort
        }
    }

    /// Servíruje JPEG crop dané detekce z in-memory `recents` bufferu.
    /// Path format: `/api/crop/<id>.jpg`. Při miss → 404.
    private func cropImageResponse(path: String) -> Data {
        guard let state else {
            return Self.httpResponseText(code: 500, body: "no state")
        }
        // "/api/crop/42.jpg" → 42
        let trimmed = path
            .replacingOccurrences(of: "/api/crop/", with: "")
            .replacingOccurrences(of: ".jpg", with: "")
        guard let id = Int(trimmed) else {
            return Self.httpResponseText(code: 400, body: "bad id")
        }
        guard let rec = state.recents.items.first(where: { $0.id == id }),
              let nsImg = rec.cropImage,
              let tiff = nsImg.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return Self.httpResponseText(code: 404, body: "no crop")
        }
        return Self.httpResponseData(code: 200, body: jpeg, contentType: "image/jpeg",
                                     extraHeaders: ["Cache-Control": "public, max-age=3600"])
    }

    // MARK: - Auth

    /// Non-static — potřebuje read live password z AppState (user-changeable).
    /// Volá se z route() na MainActor, state access safe.
    private func checkAuth(header: String) -> Bool {
        // "Authorization: Basic base64(user:pass)"
        let parts = header.components(separatedBy: " ")
        guard parts.count >= 3, parts[1].lowercased() == "basic" else { return false }
        guard let data = Data(base64Encoded: parts[2]),
              let creds = String(data: data, encoding: .utf8) else { return false }
        guard let colonIdx = creds.firstIndex(of: ":") else { return false }
        let user = String(creds[..<colonIdx])
        let pass = String(creds[creds.index(after: colonIdx)...])
        let expected = state?.webUIPassword ?? ""
        return Self.constantTimeEquals(user, Self.authUser) && Self.constantTimeEquals(pass, expected)
    }

    /// Ověří že POST pochází ze stejného originu (= naše webUI). Akceptuje request:
    ///   - bez Origin i Referer (některé HTTP klienti / curl — důvěřujeme Basic Auth)
    ///   - s Origin jehož authority (host:port) == Host header
    ///   - s Referer (fallback) jehož authority == Host header
    /// Odmítne request s EXPLICITNÍM Origin/Referer z jiného hostu — to je přesně
    /// CSRF útok přes malicious webovou stránku.
    ///
    /// **Strict authority compare** (ne substring) — `https://198.51.100.119:22224`
    /// se parsuje a porovnává se HostValue na přesnou shodu. Dřívější `contains()`
    /// šel obejít adresou `https://evil.com/?r=198.51.100.119:22224` která by
    /// stringový-match prošla.
    nonisolated private static func checkSameOrigin(host: String, origin: String, referer: String) -> Bool {
        let hostVal = parseHeaderValue(host).lowercased()
        guard !hostVal.isEmpty else { return false }

        let originVal = parseHeaderValue(origin).lowercased()
        if !originVal.isEmpty {
            return extractAuthority(originVal) == hostVal
        }

        let refererVal = parseHeaderValue(referer).lowercased()
        if !refererVal.isEmpty {
            return extractAuthority(refererVal) == hostVal
        }

        // Bez Origin i Referer → ne-browser klient (curl, Postman).
        // Důvěřujeme Basic Auth že kredenciály má — CSRF vyžaduje cookie/cached creds
        // session v browseru, ne u CLI toolu.
        return true
    }

    /// Extrahuje hodnotu z HTTP header řádky „Name: value" — všechno za prvním `:`.
    nonisolated private static func parseHeaderValue(_ header: String) -> String {
        header.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Extrahuje authority (host[:port]) z URL podobného stringu.
    /// Akceptované formáty:
    ///   - `https://198.51.100.119:22224/path` → `198.51.100.119:22224`
    ///   - `https://198.51.100.119:22224`      → `198.51.100.119:22224`
    ///   - `198.51.100.119:22224`               → `198.51.100.119:22224` (bez schéma)
    ///   - `null`                              → `` (bad origin)
    nonisolated private static func extractAuthority(_ urlString: String) -> String {
        var s = urlString
        for prefix in ["https://", "http://"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
        }
        // Cut cestu/query/fragment za prvním `/`, `?`, `#` — authority končí tam.
        if let idx = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<idx])
        }
        if s == "null" { return "" }
        return s
    }

    /// Parse comma-separated CIDR list a zkontroluje jestli client IP matchne
    /// některý range. Podporuje IPv4 only (firemní LAN je IPv4). Empty/invalid
    /// CIDR skip. Pokud žádný nematch → false (= 403).
    nonisolated static func ipMatchesAnyCIDR(_ ip: String, cidrs: String) -> Bool {
        guard let ipVal = Self.ipv4ToUInt32(ip) else { return false }
        for chunk in cidrs.components(separatedBy: ",") {
            let cidr = chunk.trimmingCharacters(in: .whitespaces)
            guard !cidr.isEmpty else { continue }
            let parts = cidr.components(separatedBy: "/")
            guard parts.count == 2,
                  let base = Self.ipv4ToUInt32(parts[0]),
                  let prefix = Int(parts[1]),
                  prefix >= 0, prefix <= 32 else { continue }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
            if (ipVal & mask) == (base & mask) { return true }
        }
        return false
    }

    nonisolated private static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for p in parts {
            guard let n = UInt32(p), n <= 255 else { return nil }
            result = (result << 8) | n
        }
        return result
    }

    nonisolated private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    // MARK: - Actions

    // MARK: - Codable status payload

    /// Codable struktury pro `/api/status` — JSONEncoder zaručí proper escaping
    /// (uvozovky, backslashe, control chars) bez ručního string concat.
    private struct GateState: Encodable {
        let enabled: Bool
        let lastGateOpenAt: Int64
        let gateOpenDurationMs: Int
        let lastShellySummary: String
        let lastShellyOK: Bool
        let lastShellyAt: Int64
    }
    private struct StatusPayload: Encodable {
        let lastDetection: DetectionListItem?
        let vjezd: [DetectionListItem]
        let vyjezd: [DetectionListItem]
        // Per-camera gate state. `vjezdGate` zachovává také mirror v top-level
        // polích pro back-compat s existing webUI HTML JS (před multi-camera).
        let vjezdGate: GateState
        let vyjezdGate: GateState
        let lastGateOpenAt: Int64
        let gateOpenDurationMs: Int
        let lastShellySummary: String
        let lastShellyOK: Bool
        let lastShellyAt: Int64
    }

    private struct DetectionListItem: Encodable {
        let id: Int?           // nil pro list položky (SQLite query nevrací RecentBuffer id)
        let plate: String
        let time: String       // ISO8601
        let hasImg: Bool?      // jen v lastDetection
        let camera: String?    // jen v lastDetection
        let vehicle_type: String?
        let vehicle_color: String?
    }

    private static let statusEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = []  // compact, žádný pretty-print
        // ISO8601DateFormatter ne-Codable; raw String fields místo `Date` typu.
        return enc
    }()

    private func statusJSON() -> String {
        guard let state else { return "{}" }

        let iso = ISO8601DateFormatter()

        func toListItem(_ r: RecentDetection, includeFullFields: Bool) -> DetectionListItem {
            DetectionListItem(
                id: includeFullFields ? r.id : nil,
                plate: r.plate,
                time: iso.string(from: r.timestamp),
                hasImg: includeFullFields ? (r.cropImage != nil) : nil,
                camera: includeFullFields ? r.cameraName : nil,
                vehicle_type: r.vehicleType,
                vehicle_color: r.vehicleColor
            )
        }

        let lastDetection = state.recents.items.first.map { toListItem($0, includeFullFields: true) }

        // Posledních 5 detekcí per kamera ze SQLite — in-memory `recents` má
        // merge window (stejná SPZ → 1 item). DB má všechny commity separátně.
        let vjezdRaw = Store.shared.queryDetections(camera: "vjezd", limit: 5)
        let vyjezdRaw = Store.shared.queryDetections(camera: "vyjezd", limit: 5)
        let vyjezdLegacy = Store.shared.queryDetections(camera: "výjezd", limit: 5)
        let vjezd = Array(vjezdRaw.prefix(5)).map { toListItem($0, includeFullFields: false) }
        let vyjezd = Array((vyjezdRaw + vyjezdLegacy).sorted { $0.timestamp > $1.timestamp }.prefix(5))
            .map { toListItem($0, includeFullFields: false) }

        let toMs: (Date?) -> Int64 = { d in
            guard let d else { return 0 }
            return Int64(d.timeIntervalSince1970 * 1000)
        }
        let vjezdGate = GateState(
            enabled: state.shellyVjezdEnabled,
            lastGateOpenAt: toMs(state.gateOpenEventAt),
            gateOpenDurationMs: Int(state.gateOpenDurationSec * 1000),
            lastShellySummary: state.lastShellySummary,
            lastShellyOK: state.lastShellyOK,
            lastShellyAt: toMs(state.lastShellyAt)
        )
        let vyjezdGate = GateState(
            enabled: state.shellyVyjezdEnabled,
            lastGateOpenAt: toMs(state.gateOpenEventAtVyjezd),
            gateOpenDurationMs: Int(state.gateOpenDurationSecVyjezd * 1000),
            lastShellySummary: state.lastShellySummaryVyjezd,
            lastShellyOK: state.lastShellyOKVyjezd,
            lastShellyAt: toMs(state.lastShellyAtVyjezd)
        )

        let payload = StatusPayload(
            lastDetection: lastDetection,
            vjezd: vjezd,
            vyjezd: vyjezd,
            vjezdGate: vjezdGate,
            vyjezdGate: vyjezdGate,
            lastGateOpenAt: vjezdGate.lastGateOpenAt,
            gateOpenDurationMs: vjezdGate.gateOpenDurationMs,
            lastShellySummary: vjezdGate.lastShellySummary,
            lastShellyOK: vjezdGate.lastShellyOK,
            lastShellyAt: vjezdGate.lastShellyAt
        )
        guard let data = try? Self.statusEncoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// Async open-gate handler — await webhook fire result + responde s HTTP code
    /// reflecting actual relay outcome.
    ///
    /// **Rev 6 design:** webUI cesta musí být honest stejně jako ALPR. Banner
    /// `markGateOpened()` se nyní zavolá JEN při `.success`. UI zobrazí přesný
    /// status (200 ok / 502 unreachable / 400 SSRF / 429 rate limited). Bez
    /// webhookURL banner zasvítí (no-relay use case = jen vizuální feedback).
    private func openGateActionAsync() async -> Data {
        guard let state else {
            return Self.httpResponseText(code: 500, body: "{\"ok\":false}", contentType: "application/json")
        }

        let action = pendingOpenGateAction
        let camera = pendingOpenGateCamera
        let device = state.shellyDevice(for: camera)

        // Per-camera disabled — vrátí 403 ihned, žádný banner (user vidí
        // disabled stav v Settings UI).
        if !device.enabled {
            return Self.httpResponseText(code: 403,
                body: "{\"ok\":false,\"error\":\"\(camera) Shelly disabled\"}",
                contentType: "application/json")
        }

        // Side effects (audit + manual snapshot + macOS notification) jen po
        // úspěšném fire — 502 (relay unreachable) nesmí logovat "Závora otevřena".
        let recordSuccessSideEffects: () -> Void = { [weak self] in
            guard let self else { return }
            if let svc = self.cameras?.services[camera], let pb = svc.snapshotLatest() {
                let ci = CIImage(cvPixelBuffer: pb)
                if let cg = SharedCIContext.shared.createCGImage(ci, from: ci.extent) {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    _ = Store.shared.persistManualPass(cameraName: camera, fullImage: img)
                }
            }
            NotificationHelper.post(title: "Závora otevřena (\(camera))",
                                     body: "Vzdálený příkaz z webového UI")
            self.log("remote open-gate fired (success) camera=\(camera)")
        }

        // Hold mode jen pro vjezd — výjezd typicky pulse-only (auto vyjede).
        // GateHoldController is single-instance, vázaný na vjezd device.
        if action == .openHoldStart {
            guard camera == "vjezd" else {
                return Self.httpResponseText(code: 400,
                    body: "{\"ok\":false,\"error\":\"hold mode jen pro vjezd\"}",
                    contentType: "application/json")
            }
            GateHoldController.shared.start(state: state)
            state.markGateOpened(camera: camera,
                                  duration: state.bannerDuration(for: .openHoldStart, camera: camera))
            log("remote open-gate HOLD start")
            return Self.httpResponseText(code: 200,
                body: "{\"ok\":true,\"action\":\"hold-start\"}",
                contentType: "application/json")
        }
        if action == .closeRelease {
            if camera == "vjezd" { GateHoldController.shared.stop() }
            state.markGateClosed(camera: camera)
            if device.isUsable {
                let cfg = device.gateActionConfig()
                let t0 = Date()
                let releaseResult = await WebhookClient.shared.fireGateAction(
                    .closeRelease, baseURL: device.baseURL,
                    user: device.user, password: device.password,
                    plate: "WEB", camera: camera, config: cfg,
                    eventId: "WEB-\(camera)-closeRelease-\(UUID().uuidString.prefix(8))",
                    timeout: 2.0)
                state.recordShellyResult(releaseResult, camera: camera,
                                          latencyMs: Int(Date().timeIntervalSince(t0) * 1000))
            }
            log("remote open-gate HOLD release camera=\(camera)")
            return Self.httpResponseText(code: 200,
                body: "{\"ok\":true,\"action\":\"close-release\"}",
                contentType: "application/json")
        }

        // Bez relé URL — banner ano, status ok (no-relay setup).
        if device.baseURL.isEmpty {
            state.markGateOpened(camera: camera,
                                  duration: state.bannerDuration(for: action, camera: camera))
            recordSuccessSideEffects()
            return Self.httpResponseText(code: 200, body: "{\"ok\":true,\"relay\":\"no-url\"}",
                                          contentType: "application/json")
        }

        // Scenario fire — per-camera Shelly device + auth.
        let t0 = Date()
        let cfg = device.gateActionConfig()
        let result = await WebhookClient.shared.fireGateAction(
            action, baseURL: device.baseURL,
            user: device.user, password: device.password,
            plate: "WEB", camera: camera, config: cfg,
            eventId: "WEB-\(camera)-\(action.auditTag)-\(UUID().uuidString.prefix(8))",
            timeout: 2.0)
        let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)
        state.recordShellyResult(result, camera: camera, latencyMs: latencyMs)
        switch result {
        case .success(let httpStatus):
            state.markGateOpened(camera: camera,
                                  duration: state.bannerDuration(for: action, camera: camera))
            recordSuccessSideEffects()
            return Self.httpResponseText(code: 200,
                body: "{\"ok\":true,\"http_status\":\(httpStatus),\"ms\":\(latencyMs)}",
                contentType: "application/json")
        case .rejectedBySSRF(let reason):
            log("remote open-gate REJECTED (SSRF): \(reason)")
            return Self.httpResponseText(code: 400,
                body: "{\"ok\":false,\"error\":\"webhook URL blocked: \(reason)\"}",
                contentType: "application/json")
        case .networkError, .httpError, .redirectBlocked:
            log("remote open-gate FAILED (\(result))")
            return Self.httpResponseText(code: 502,
                body: "{\"ok\":false,\"error\":\"gate device unreachable\"}",
                contentType: "application/json")
        case .rateLimited:
            log("remote open-gate rate-limited")
            return Self.httpResponseText(code: 429,
                body: "{\"ok\":false,\"error\":\"rate limited, try again\"}",
                contentType: "application/json")
        }
    }

    private func addDailyAction(body: String) -> String {
        guard let state else { return "{\"ok\":false,\"error\":\"no state\"}" }
        var params: [String: String] = [:]
        for pair in body.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                params[kv[0]] = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
            }
        }
        guard let plate = params["plate"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plate.isEmpty else {
            return "{\"ok\":false,\"error\":\"Chybí SPZ\"}"
        }
        let label = (params["label"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = label.isEmpty ? "Webový denní vjezd" : label
        let expiry = Date().addingTimeInterval(TimeInterval(state.dailyPassExpiryHours) * 3600)
        KnownPlates.shared.add(plate: plate, label: finalLabel, expiresAt: expiry, auditSource: .webUI)
        state.dailyPassesAddedTotal += 1
        log("remote add-daily plate=\(plate) label=\(finalLabel)")
        return "{\"ok\":true}"
    }

    // MARK: - HTTP response builder

    nonisolated private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Error"
        }
    }

    nonisolated private static func httpResponseText(code: Int, body: String,
                                                     contentType: String = "text/plain; charset=utf-8") -> Data {
        let bodyData = body.data(using: .utf8) ?? Data()
        return httpResponseData(code: code, body: bodyData, contentType: contentType)
    }

    nonisolated private static func httpResponseData(code: Int, body: Data, contentType: String,
                                                     extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(code) \(statusText(code))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if extraHeaders["Cache-Control"] == nil {
            head += "Cache-Control: no-store\r\n"
        }
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = head.data(using: .utf8) ?? Data()
        out.append(body)
        return out
    }

    nonisolated private func log(_ msg: String) {
        FileHandle.safeStderrWrite("[WebServer] \(msg)\n".data(using: .utf8)!)
    }

    // MARK: - HTML page

    nonisolated private static let indexHTML: String = """
        <!DOCTYPE html>
        <html lang="cs">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>SPZ · ALPR</title>
        <style>
        /* Tokens — mapping na DesignSystem.swift (DS.Color / DS.Typo / DS.Space). */
        :root {
          --bg0: #0e1016;
          --surface-top: rgba(255,255,255,.06);
          --surface-bot: rgba(255,255,255,.02);
          --border: rgba(255,255,255,.10);
          --hairline: rgba(255,255,255,.08);
          --text-primary: rgba(255,255,255,.96);
          --text-secondary: rgba(255,255,255,.62);
          --text-tertiary: rgba(255,255,255,.40);
          --success: #32d74b; /* SF Green */
          --warning: #ff9f0a; /* SF Orange */
          --danger:  #ff453a; /* SF Red */
          --info:    #0a84ff; /* SF Blue */
          --accent:  #bf5af2; /* SF Purple */
        }
        * { box-sizing: border-box; }
        html, body { -webkit-font-smoothing: antialiased; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif;
          background: var(--bg0); color: var(--text-primary);
          margin: 0; padding: 14px; max-width: 880px; margin: 0 auto;
          font-size: 12px; font-weight: 500; }
        /* Glassmorphic card — DSCardBackground (ultraThinMaterial + gradient + hairline). */
        .card { position: relative; padding: 0; margin-bottom: 10px;
          border-radius: 12px; overflow: hidden;
          background:
            linear-gradient(180deg, var(--surface-top), var(--surface-bot)),
            rgba(20,22,28,.72);
          backdrop-filter: blur(28px) saturate(1.2);
          -webkit-backdrop-filter: blur(28px) saturate(1.2);
          border: 0.5px solid var(--border); }
        .card .body { padding: 10px 14px; }
        .card .head {
          display: flex; align-items: center; gap: 10px;
          padding: 10px 14px; border-bottom: 0.5px solid var(--hairline); }
        .card .head .title {
          font-size: 11px; font-weight: 600; letter-spacing: 1.4px;
          text-transform: uppercase; color: var(--text-primary); }
        .card .head .icon { font-size: 10px; color: var(--text-tertiary); width: 14px; }
        .card .head .icon.vjezd { color: var(--success); }
        .card .head .icon.vyjezd { color: var(--info); }
        .card .head .spacer { flex: 1; }

        /* Gate-action button grid: 1 primární full-width + 3 secondary v řádce. */
        .gate-grid { display: grid; grid-template-columns: 1fr; gap: 8px; }
        .btn-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
        @media (max-width: 420px) { .btn-row { grid-template-columns: repeat(3, 1fr); } }

        button { font-family: inherit; cursor: pointer; border: 0;
          font-weight: 600; letter-spacing: 1.2px; text-transform: uppercase;
          transition: transform .08s ease, filter .12s ease, background .12s ease;
          width: 100%; }
        button:active { transform: scale(.97); filter: brightness(1.08); }
        button:disabled { opacity: .45; cursor: not-allowed; }

        /* Primární — výrazný success-tint solid. */
        .btn-primary {
          background: var(--success); color: #000;
          padding: 14px 18px; font-size: 12px; border-radius: 10px;
          letter-spacing: 1.5px; }
        /* Secondary — outlined / ghost s tintem. */
        .btn-secondary {
          background: rgba(255,255,255,.04); color: var(--text-primary);
          padding: 11px 12px; font-size: 10px; border-radius: 8px;
          border: 0.5px solid var(--border); }
        .btn-secondary:hover { background: rgba(255,255,255,.07); }
        .btn-secondary.warn { color: var(--warning); border-color: rgba(255,159,10,.35); }
        .btn-secondary.warn:hover { background: rgba(255,159,10,.12); }
        .btn-secondary.info { color: var(--info); border-color: rgba(10,132,255,.35); }
        .btn-secondary.info:hover { background: rgba(10,132,255,.12); }
        .btn-secondary.danger { color: var(--danger); border-color: rgba(255,69,58,.35); }
        .btn-secondary.danger:hover { background: rgba(255,69,58,.12); }
        /* Reveal toggle (pro denní vjezd) — neutral ghost, plná šířka. */
        .btn-reveal {
          background: rgba(255,255,255,.04); color: var(--text-secondary);
          padding: 10px 14px; font-size: 10px; border-radius: 8px;
          border: 0.5px solid var(--border);
          display: flex; align-items: center; justify-content: center; gap: 8px; }
        .btn-reveal:hover { background: rgba(255,255,255,.07); color: var(--text-primary); }
        .btn-reveal .chev { font-size: 8px; transition: transform .2s; }
        .btn-reveal.open .chev { transform: rotate(180deg); }

        /* Inputs */
        input { background: rgba(255,255,255,.04); color: var(--text-primary);
          border: 0.5px solid var(--border); padding: 10px 12px;
          border-radius: 8px; width: 100%; margin-bottom: 8px; font-size: 12px;
          font-family: inherit; font-weight: 500; }
        input:focus { outline: 1px solid var(--success); border-color: transparent; }
        input::placeholder { color: var(--text-tertiary); }

        /* Status messages */
        .msg { font-size: 10px; margin-top: 8px; min-height: 14px; font-weight: 600;
          letter-spacing: 0.6px; text-transform: uppercase; }
        .msg.ok { color: var(--success); }
        .msg.err { color: var(--danger); }

        /* Detekční karty — dvousloupcový grid */
        .cols { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-bottom: 10px; }
        @media (max-width: 560px) { .cols { grid-template-columns: 1fr; } }

        /* Detekce row — bez timestampu, jen plate + camera. */
        .row { display: flex; align-items: center; gap: 10px;
          padding: 7px 0; border-top: 0.5px solid var(--hairline); }
        .row:first-child { border-top: 0; padding-top: 2px; }
        .plate { font-family: 'SF Mono', Menlo, monospace; font-size: 14px; font-weight: 700;
          background: var(--text-primary); color: #0e1016; padding: 3px 8px;
          border-radius: 4px; letter-spacing: 1px; flex: 0 0 auto; }
        .empty { color: var(--text-tertiary); font-size: 11px; padding: 6px 0;
          font-style: italic; }

        /* Hero — poslední detekce s fotografií */
        .hero { display: flex; flex-direction: column; gap: 10px; }
        .hero img { width: 100%; height: auto; max-height: 220px; object-fit: cover;
          border-radius: 8px; background: #000; border: 0.5px solid var(--border); }
        .hero .meta { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .hero .plate { font-size: 18px; padding: 4px 11px; }
        .hero .tstack { display: flex; flex-direction: column; align-items: flex-end;
          margin-left: auto; font-family: 'SF Mono', Menlo, monospace; line-height: 1.15; }
        .hero .tstack .h { font-size: 18px; font-weight: 700; color: var(--text-primary); }
        .hero .tstack .d { font-size: 10px; color: var(--text-secondary); margin-top: 2px; }
        .cam-badge { font-size: 9px; font-weight: 600; letter-spacing: 1.2px;
          padding: 3px 7px; border-radius: 4px;
          background: rgba(255,255,255,.04); border: 0.5px solid var(--border);
          text-transform: uppercase; }
        .cam-badge.vjezd { color: var(--success); border-color: rgba(50,215,75,.35);
          background: rgba(50,215,75,.10); }
        .cam-badge.vyjezd { color: var(--info); border-color: rgba(10,132,255,.35);
          background: rgba(10,132,255,.10); }

        /* Banner — ZÁVORA OTEVŘENA — duration sync s real gate-open timerem */
        #banner { position: fixed; left: 10px; right: 10px; top: 10px; z-index: 50;
          display: none; align-items: center; justify-content: center; gap: 10px;
          padding: 12px 18px; border-radius: 12px; color: #000;
          background: var(--success);
          font-size: 12px; font-weight: 700; letter-spacing: 2px;
          text-transform: uppercase;
          box-shadow: 0 8px 24px rgba(50,215,75,.32);
          animation: slide .22s ease-out; }
        #banner.on { display: flex; }
        #banner svg { width: 16px; height: 16px; }
        @keyframes slide { from { transform: translateY(-16px); opacity: 0 } to { transform: translateY(0); opacity: 1 } }

        /* Shelly response — abbreviated status row pod gate ovládáním */
        .shelly-row { display: flex; align-items: center; gap: 8px;
          margin-top: 8px; padding-top: 8px; border-top: 0.5px solid var(--hairline);
          font-size: 10px; letter-spacing: 0.6px; text-transform: uppercase;
          color: var(--text-secondary); font-weight: 600; }
        .shelly-dot { width: 7px; height: 7px; border-radius: 50%;
          background: var(--text-tertiary); flex: 0 0 auto; }
        .shelly-dot.ok { background: var(--success); box-shadow: 0 0 6px rgba(50,215,75,.55); }
        .shelly-dot.err { background: var(--danger); }
        .shelly-label { color: var(--text-tertiary); }
        .shelly-value { color: var(--text-primary); font-family: 'SF Mono', Menlo, monospace;
          letter-spacing: 0.4px; text-transform: none; }
        .shelly-value.err { color: var(--danger); }
        .shelly-age { margin-left: auto; color: var(--text-tertiary);
          font-family: 'SF Mono', Menlo, monospace; font-weight: 500;
          letter-spacing: 0.2px; text-transform: none; }

        /* Reveal panel — denní vjezd se schová pod tlačítko */
        .reveal { max-height: 0; overflow: hidden; transition: max-height .25s ease; }
        .reveal.open { max-height: 280px; }
        </style>
        </head>
        <body>
        <div id="banner">
          <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 1a5 5 0 0 0-5 5v3H5v13h14V9h-7V6a3 3 0 0 1 6 0h2a5 5 0 0 0-5-5z"/></svg>
          <span>Závora otevřena</span>
        </div>

        <!-- VJEZD ovládání: hlavní OTEVŘÍT + autobus / držet / zavřít -->
        <div class="card" id="vjezdCard">
          <div class="head"><span class="icon vjezd">●</span><span class="title">Vjezd</span></div>
          <div class="body">
            <div class="gate-grid">
              <button class="btn-primary" onclick="gateAction('short','vjezd',this)">Otevřít vjezd</button>
              <div class="btn-row">
                <button class="btn-secondary info" onclick="gateAction('extended','vjezd',this)" title="Delší impulz pro autobus / nákladní">Autobus</button>
                <button class="btn-secondary warn" onclick="gateAction('hold','vjezd',this)" title="Otevřít a držet (nutno zavřít)">Držet</button>
                <button class="btn-secondary danger" onclick="gateAction('release','vjezd',this)" title="Ukončit držení / zavřít">Zavřít</button>
              </div>
            </div>
            <div id="vjezdMsg" class="msg"></div>
            <div class="shelly-row">
              <span class="shelly-dot" id="vjezdShellyDot"></span>
              <span class="shelly-label">Shelly</span>
              <span class="shelly-value" id="vjezdShellyValue">—</span>
              <span class="shelly-age" id="vjezdShellyAge"></span>
            </div>
          </div>
        </div>

        <!-- VÝJEZD ovládání — pouze short + autobus (hold mode jen pro vjezd) -->
        <div class="card" id="vyjezdCard" style="display:none">
          <div class="head"><span class="icon vyjezd">●</span><span class="title">Výjezd</span></div>
          <div class="body">
            <div class="gate-grid">
              <button class="btn-primary" onclick="gateAction('short','vyjezd',this)">Otevřít výjezd</button>
              <div class="btn-row" style="grid-template-columns: 1fr">
                <button class="btn-secondary info" onclick="gateAction('extended','vyjezd',this)" title="Delší impulz pro autobus / nákladní">Autobus</button>
              </div>
            </div>
            <div id="vyjezdMsg" class="msg"></div>
            <div class="shelly-row">
              <span class="shelly-dot" id="vyjezdShellyDot"></span>
              <span class="shelly-label">Shelly</span>
              <span class="shelly-value" id="vyjezdShellyValue">—</span>
              <span class="shelly-age" id="vyjezdShellyAge"></span>
            </div>
          </div>
        </div>

        <!-- Denní vjezd — schované pod tlačítkem -->
        <div class="card">
          <div class="body">
            <button id="dailyToggle" class="btn-reveal" onclick="toggleDaily()" type="button">
              <span>Přidat denní vjezd</span>
              <span class="chev">▼</span>
            </button>
            <div id="dailyPanel" class="reveal">
              <div style="height:10px"></div>
              <input id="plate" placeholder="SPZ (např. 5T2 1234)" autocomplete="off" autocapitalize="characters" maxlength="10">
              <input id="label" placeholder="Jméno / firma" autocomplete="off" maxlength="60">
              <button class="btn-secondary info" onclick="addDaily()">Přidat</button>
              <div id="addMsg" class="msg"></div>
            </div>
          </div>
        </div>

        <!-- Poslední detekce s fotografií + časem -->
        <div class="card">
          <div class="head"><span class="icon">◉</span><span class="title">Poslední detekce</span></div>
          <div class="body">
            <div id="lastDet"><div class="empty">načítám…</div></div>
          </div>
        </div>

        <!-- Posledních 5 vjezd / výjezd — bez časů -->
        <div class="cols">
          <div class="card">
            <div class="head"><span class="icon vjezd">●</span><span class="title">Vjezd · 5×</span></div>
            <div class="body"><div id="vjezd"><div class="empty">načítám…</div></div></div>
          </div>
          <div class="card">
            <div class="head"><span class="icon vyjezd">●</span><span class="title">Výjezd · 5×</span></div>
            <div class="body"><div id="vyjezd"><div class="empty">načítám…</div></div></div>
          </div>
        </div>

        <script>
        // Tracking gate-open eventů — banner duration sync s real gate-open timerem
        // (`gateOpenDurationMs` ze /api/status). Pro short pulse 1 s, autobus 20 s,
        // hold ~24 h (release ho zruší okamžitě).
        let lastSeenGateOpen = 0;
        let bannerHideTimer = null;
        function showBanner(durationMs) {
          const b = document.getElementById('banner');
          b.classList.add('on');
          if (bannerHideTimer) clearTimeout(bannerHideTimer);
          const ms = Math.max(800, durationMs || 5000);
          bannerHideTimer = setTimeout(() => b.classList.remove('on'), ms);
        }
        function hideBanner() {
          const b = document.getElementById('banner');
          b.classList.remove('on');
          if (bannerHideTimer) clearTimeout(bannerHideTimer);
        }

        function parseTime(iso) {
          const d = new Date(iso);
          const pad = n => String(n).padStart(2, '0');
          return {
            time: pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()),
            date: pad(d.getDate()) + '.' + pad(d.getMonth() + 1) + '.' + String(d.getFullYear()).slice(-2)
          };
        }

        // Bez timestampu — user feedback: u list položek nepotřebujeme čas.
        // Pořadí je top→bottom == nejnovější→nejstarší.
        function fmtRow(x) {
          return '<div class="row"><span class="plate">' + x.plate + '</span></div>';
        }
        function renderList(containerId, items) {
          const el = document.getElementById(containerId);
          if (!items || items.length === 0) {
            el.innerHTML = '<div class="empty">žádná data</div>';
            return;
          }
          el.innerHTML = items.map(fmtRow).join('');
        }
        function renderLastDetection(x) {
          const el = document.getElementById('lastDet');
          if (!x) { el.innerHTML = '<div class="empty">žádná detekce</div>'; return; }
          const t = parseTime(x.time);
          const camKey = (x.camera === 'vjezd') ? 'vjezd' : 'vyjezd';
          const camLabel = (x.camera === 'vjezd') ? 'Vjezd' : 'Výjezd';
          const img = x.hasImg ? '<img src="/api/crop/' + x.id + '.jpg" alt="">' : '';
          el.innerHTML = '<div class="hero">'
            + img
            + '<div class="meta">'
            + '<span class="plate">' + x.plate + '</span>'
            + '<span class="cam-badge ' + camKey + '">' + camLabel + '</span>'
            + '<span class="tstack"><span class="h">' + t.time + '</span>'
            + '<span class="d">' + t.date + '</span></span>'
            + '</div></div>';
        }
        // Banner visibility — držet podle nejnovějšího (vjezd / vyjezd) gate eventu.
        // Server zhasne banner setem at=0 (po release).
        function syncBannerFromGates(g) {
          const at = Math.max(g.vjezd?.lastGateOpenAt || 0, g.vyjezd?.lastGateOpenAt || 0);
          const dur = (g.vjezd?.lastGateOpenAt >= (g.vyjezd?.lastGateOpenAt || 0))
            ? (g.vjezd?.gateOpenDurationMs || 0)
            : (g.vyjezd?.gateOpenDurationMs || 0);
          if (at === 0) { hideBanner(); return; }
          const remaining = (at + dur) - Date.now();
          if (remaining <= 0) { hideBanner(); return; }
          if (at > lastSeenGateOpen) {
            if (lastSeenGateOpen !== 0) showBanner(remaining);
            lastSeenGateOpen = at;
          }
        }

        function fmtAge(deltaMs) {
          if (deltaMs < 0) return '';
          const s = Math.floor(deltaMs / 1000);
          if (s < 60) return s + ' s';
          const m = Math.floor(s / 60);
          if (m < 60) return m + ' min';
          return Math.floor(m / 60) + ' h';
        }
        function renderShellyRow(prefix, gate) {
          const dot = document.getElementById(prefix + 'ShellyDot');
          const val = document.getElementById(prefix + 'ShellyValue');
          const age = document.getElementById(prefix + 'ShellyAge');
          if (!dot || !val) return;
          const sum = gate?.lastShellySummary || '';
          if (!sum || !gate?.lastShellyAt) {
            dot.className = 'shelly-dot';
            val.className = 'shelly-value';
            val.textContent = '—';
            age.textContent = '';
            return;
          }
          dot.className = 'shelly-dot ' + (gate.lastShellyOK ? 'ok' : 'err');
          val.className = 'shelly-value' + (gate.lastShellyOK ? '' : ' err');
          val.textContent = sum;
          age.textContent = fmtAge(Date.now() - gate.lastShellyAt);
        }

        async function refresh() {
          try {
            const r = await fetch('/api/status');
            const d = await r.json();
            renderLastDetection(d.lastDetection);
            renderList('vjezd', d.vjezd);
            renderList('vyjezd', d.vyjezd);
            // Per-camera Shelly row + banner
            renderShellyRow('vjezd', d.vjezdGate);
            renderShellyRow('vyjezd', d.vyjezdGate);
            // Show/hide vyjezd card podle enabled stavu serveru
            const vyjezdCard = document.getElementById('vyjezdCard');
            if (vyjezdCard) {
              vyjezdCard.style.display = d.vyjezdGate?.enabled ? '' : 'none';
            }
            syncBannerFromGates({ vjezd: d.vjezdGate, vyjezd: d.vyjezdGate });
          } catch(e) {}
        }

        // Univerzální gate trigger — action: short|extended|hold|release.
        // camera: vjezd|vyjezd. Per-camera msg div: `<camera>Msg`.
        async function gateAction(action, camera, btn) {
          const msg = document.getElementById(camera + 'Msg');
          if (btn) btn.disabled = true;
          try {
            const r = await fetch('/api/open-gate?action=' + encodeURIComponent(action)
              + '&camera=' + encodeURIComponent(camera), {method:'POST'});
            const d = await r.json();
            if (d.ok) {
              const labels = { short:'Otevřeno', extended:'Otevřeno (autobus)',
                               hold:'Drží otevřené', release:'Zavřeno' };
              const httpInfo = d.http_status ? (' · ' + d.http_status + (d.ms ? ' · ' + d.ms + ' ms' : '')) : '';
              if (msg) {
                msg.textContent = (labels[action] || 'OK') + httpInfo;
                msg.className = 'msg ok';
              }
              if (action === 'release') hideBanner();
              refresh();
            } else {
              if (msg) {
                msg.textContent = d.error || 'Chyba';
                msg.className = 'msg err';
              }
              refresh();
            }
          } catch(e) {
            if (msg) {
              msg.textContent = 'Chyba spojení';
              msg.className = 'msg err';
            }
          }
          setTimeout(() => {
            if (btn) btn.disabled = false;
            if (msg) msg.textContent = '';
          }, 6000);
        }

        function toggleDaily() {
          const panel = document.getElementById('dailyPanel');
          const btn = document.getElementById('dailyToggle');
          panel.classList.toggle('open');
          btn.classList.toggle('open');
          if (panel.classList.contains('open')) {
            setTimeout(() => document.getElementById('plate').focus(), 100);
          }
        }

        async function addDaily() {
          const plate = document.getElementById('plate').value.trim();
          const label = document.getElementById('label').value.trim();
          const msg = document.getElementById('addMsg');
          if (!plate) { msg.textContent='Zadej SPZ'; msg.className='msg err'; return; }
          const body = 'plate='+encodeURIComponent(plate)+'&label='+encodeURIComponent(label);
          try {
            const r = await fetch('/api/add-daily', {method:'POST', body, headers:{'Content-Type':'application/x-www-form-urlencoded'}});
            const d = await r.json();
            if (d.ok) {
              msg.textContent = 'Přidáno: ' + plate; msg.className='msg ok';
              document.getElementById('plate').value='';
              document.getElementById('label').value='';
            } else {
              msg.textContent = d.error || 'Chyba'; msg.className='msg err';
            }
          } catch(e) { msg.textContent='Chyba spojení'; msg.className='msg err'; }
          setTimeout(() => msg.textContent = '', 4000);
        }
        refresh();
        setInterval(refresh, 2000);
        </script>
        </body>
        </html>
        """
}
