import Foundation
import Network
import CryptoKit

/// Native RTSP client postavený na Apple Network.framework. Implementuje:
///
/// - **TCP connection** k IP kameře přes NWConnection
/// - **RTSP request/response** parsing (text protocol per RFC 2326)
/// - **HTTP Digest authentication** (RFC 2617) — VIGI vyžaduje
/// - **Interleaved RTP-over-TCP** dle RFC 2326 § 10.12 (channel-prefixed RTP packets na
///   stejném TCP socketu jako RTSP control). Jednodušší než UDP — žádný NAT punch,
///   žádný packet loss, garance order.
/// - **Keepalive OPTIONS** každých 25 s
/// - **Watchdog** — pokud žádný RTP packet >30 s, signalizuje disconnect
///
/// Lifecycle: `connect()` → DESCRIBE (returns SDP) → SETUP (track1 with TCP interleave)
/// → PLAY → packets arrive via `onRTPPacket` callback → `disconnect()` (TEARDOWN).
final class RTSPClient {
    // MARK: - Public API

    enum State {
        case idle, connecting, describing, settingUp, playing, error(String), closed
    }

    var onSDPReceived: ((SDPDescription) -> Void)?
    var onRTPPacket: ((Data) -> Void)?
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            FileHandle.safeStderrWrite("[RTSPClient] state → \(state)\n".data(using: .utf8)!)
            onStateChange?(state)
        }
    }
    private var rtpPacketCount: Int = 0

    /// Nominální pixelové rozlišení odhadnuté ze SDP (může být imprecise — autoritativní
    /// dimenze přijdou až po prvním decoded frame).
    private(set) var streamHint: (width: Int, height: Int)? = nil

    // MARK: - Internals

    private let url: URL
    private let host: String
    private let port: Int
    private let username: String?
    private let password: String?
    private let path: String
    private let queue: DispatchQueue

    private var connection: NWConnection?
    /// Audit fix #7: 64-byte aligned buffer s NEON-accelerated `\r\n\r\n` scan.
    /// Dřív `rxBuffer = Data()` → Swift CoW default 16-byte alignment, našel header-end
    /// byte-at-a-time. Teď posix_memalign(64) + memchr(3) NEON-backed scan.
    private let rxBuffer = AlignedRTSPBuffer(capacity: 65536)
    private var cseq: Int = 1
    private var sessionId: String? = nil
    private var sdp: SDPDescription? = nil
    private var setupURL: String = ""
    private var lastSentMethod: String = ""
    private var lastSentURL: String = ""
    /// Originální (pre-auth) headery posledního requestu. Po 401 challenge
    /// retry-ujeme stejný request s Authorization navíc; bez zachování
    /// originálních headerů bychom ztratili `Accept: application/sdp`
    /// (DESCRIBE) nebo `Transport: RTP/AVP/TCP;...` (SETUP) a VIGI by vrátil
    /// 406 / 461.
    private var lastSentHeaders: [String: String] = [:]

    // HTTP Digest challenge cache (parsed via DigestAuth helper).
    private var digestChallenge: DigestAuth.Challenge? = nil
    private var nonceCounter: Int = 0

    // Watchdog
    private var lastRTPTimestamp: Date = .distantPast
    private var keepaliveTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    var rtpStallTimeout: TimeInterval = 30.0

    /// Audit fix #6: Session keepalive interval derived from server-advertised timeout.
    /// Default 25 s (bezpečný pro většinu RTSP serverů co default 60 s session).
    /// SETUP / PLAY response `Session: <id>;timeout=N` změní tohle na `N/2`.
    private var keepaliveInterval: TimeInterval = 25.0

    /// Audit fix #5: NWConnection backpressure cap. `receive()` loop appenduje do
    /// rxBuffer bez limitu. Když depacketizer/decoder nestíhá, rxBuffer roste až
    /// do OOM. 4 MB je ~200 RTP packetů @ 1500 B — dost na burst, ale jistota proti
    /// runaway growth. Překročení → handleError → reconnect (čistší stav než OOM).
    private static let rxBufferMaxBytes: Int = 4 * 1024 * 1024

    init(url: URL, queue: DispatchQueue) throws {
        self.url = url
        self.queue = queue
        guard let host = url.host else { throw NSError(domain: "RTSPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL bez host"]) }
        self.host = host
        self.port = url.port ?? 554
        self.username = url.user?.removingPercentEncoding
        self.password = url.password?.removingPercentEncoding
        // Path bez auth (URL ho v Connection requestech musíme dávat bez user:pass).
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.user = nil; comps?.password = nil
        self.path = comps?.path ?? "/"
        self.setupURL = comps?.string ?? url.absoluteString
    }

    // MARK: - Connection

    func connect() {
        state = .connecting
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] newState in
            guard let self = self else { return }
            switch newState {
            case .ready:
                self.startReceive()
                self.sendDescribe()
            case .failed(let err):
                self.handleError("NWConnection failed: \(err)")
            case .cancelled:
                self.state = .closed
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        keepaliveTimer?.cancel(); keepaliveTimer = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        if case .playing = state, let _ = sessionId {
            sendTeardown()
        }
        connection?.cancel()
        connection = nil
        state = .closed
    }

    private func handleError(_ msg: String) {
        // Cascade guard — první error cancelne connection, pak in-flight sends
        // dostanou ECANCELED v jejich completion closures. Bez tohoto guardu by
        // každý in-flight send volal handleError znovu → cascade notifikací
        // onStateChange → multiple reconnect attempts pro single failure.
        if case .error = state { return }
        if case .closed = state { return }
        FileHandle.safeStderrWrite("[RTSPClient] error: \(msg)\n".data(using: .utf8)!)
        state = .error(msg)
        keepaliveTimer?.cancel(); keepaliveTimer = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        connection?.cancel()
        connection = nil
    }

    // MARK: - RTSP request flow

    private func sendDescribe() {
        state = .describing
        sendRequest(method: "DESCRIBE", url: setupURL, headers: ["Accept": "application/sdp"])
    }

    private func sendSetup(controlURL: String) {
        state = .settingUp
        // Interleaved RTP-over-TCP: channels 0 (RTP) + 1 (RTCP).
        sendRequest(method: "SETUP", url: controlURL, headers: [
            "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
        ])
    }

    private func sendPlay() {
        guard let session = sessionId else {
            handleError("PLAY bez Session header")
            return
        }
        sendRequest(method: "PLAY", url: setupURL, headers: ["Session": session, "Range": "npt=0.000-"])
    }

    private func sendTeardown() {
        guard let session = sessionId else { return }
        sendRequest(method: "TEARDOWN", url: setupURL, headers: ["Session": session])
    }

    private func sendOptions() {
        sendRequest(method: "OPTIONS", url: setupURL, headers: [:])
    }

    private func sendRequest(method: String, url: String, headers: [String: String]) {
        var hdr = headers
        hdr["CSeq"] = "\(cseq)"
        hdr["User-Agent"] = "SPZ-native/1.0"
        if let session = sessionId, hdr["Session"] == nil {
            hdr["Session"] = session
        }
        // Auth header z předchozí 401 challenge
        if let authHeader = buildAuthHeader(method: method, url: url) {
            hdr["Authorization"] = authHeader
        }

        var request = "\(method) \(url) RTSP/1.0\r\n"
        for (k, v) in hdr {
            request += "\(k): \(v)\r\n"
        }
        request += "\r\n"

        cseq += 1
        lastSentMethod = method
        lastSentURL = url
        lastSentHeaders = headers
        guard let data = request.data(using: .utf8) else { return }
        // Capture connection ref lokálně — v completion closure ji porovnáme
        // se current connection. Pokud se mezitím reconnect přepsal, ignorujeme
        // error (je z mrtvé connection, už není relevant).
        let myConn = connection
        connection?.send(content: data, completion: .contentProcessed { [weak self] err in
            guard let self = self, self.connection === myConn else { return }
            if let err = err {
                // Filter ECANCELED — často fire-and-forget po našem vlastním cancel
                // (handleError cascade). Spravedlivější signál je connection state
                // handler (.failed / .cancelled), ne každý in-flight send ECANCELED.
                if case .posix(.ECANCELED) = err {
                    return
                }
                self.handleError("send failed: \(err)")
            }
        })
    }

    // MARK: - Receive loop + parsing

    private func startReceive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.processBuffer()
                // Backpressure guard: pokud processBuffer() nestihl odtékat a rxBuffer
                // naběhl přes cap, signalizujeme error. Reconnect → čistý stav. Bez
                // tohoto by runaway buffer vedl na OOM v long-running pipeline.
                if self.rxBuffer.count > RTSPClient.rxBufferMaxBytes {
                    self.handleError("rxBuffer overflow (\(self.rxBuffer.count) B > \(RTSPClient.rxBufferMaxBytes) B) — consumer stalled")
                    return
                }
            }
            if let error = error {
                self.handleError("receive: \(error)")
                return
            }
            if isComplete {
                self.handleError("connection closed by peer")
                return
            }
            // continue
            self.startReceive()
        }
    }

    /// Drainuje rxBuffer — buffer obsahuje míchaná RTSP responses + interleaved RTP frames
    /// (RFC 2326 § 10.12: `$<channel:1B><len:2B><RTP packet>`). Decision: pokud první byte
    /// je `$` (0x24), je to interleaved data; jinak je to ASCII (RTSP odpověď).
    private func processBuffer() {
        while rxBuffer.count > 0 {
            if rxBuffer[0] == 0x24 {
                // Interleaved frame
                guard rxBuffer.count >= 4 else { return }
                let length = Int(rxBuffer.readUInt16BE(at: 2))
                let total = 4 + length
                guard rxBuffer.count >= total else { return }  // wait for more
                let channel = rxBuffer[1]
                let payload = rxBuffer.subdata(in: 4..<total)
                rxBuffer.removeFirst(total)
                if channel == 0 {  // RTP video channel
                    lastRTPTimestamp = Date()
                    rtpPacketCount += 1
                    if rtpPacketCount % 100 == 1 {
                        FileHandle.safeStderrWrite("[RTSPClient] rtp packet #\(rtpPacketCount) (size \(payload.count) B)\n".data(using: .utf8)!)
                    }
                    onRTPPacket?(payload)
                }
                // channel 1 (RTCP) ignorujeme — VIGI C250 RTCP nevyžaduje (testováno
                // 24+ h session). Explicit OPTIONS keepalive je reliable replacement.
            } else {
                // RTSP response — najdi double CRLF (header end) přes NEON memchr.
                guard let headerEnd = rxBuffer.findHeaderEnd() else { return }  // wait for full headers
                guard let headerStr = rxBuffer.utf8String(in: 0..<headerEnd) else {
                    handleError("response decode failed")
                    return
                }
                // Content-Length pro body
                let contentLength = parseContentLength(headerStr) ?? 0
                let totalLen = headerEnd + contentLength
                guard rxBuffer.count >= totalLen else { return }  // wait for body
                let bodyData = contentLength > 0
                    ? rxBuffer.subdata(in: headerEnd..<totalLen)
                    : Data()
                rxBuffer.removeFirst(totalLen)
                handleResponse(header: headerStr, body: bodyData)
            }
        }
    }

    private func parseContentLength(_ headers: String) -> Int? {
        let normalized = headers.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let v = line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
                return Int(v)
            }
        }
        return nil
    }

    private func handleResponse(header: String, body: Data) {
        // První řádek: "RTSP/1.0 200 OK"
        let normalized = header.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let statusLine = lines.first else { return }
        let parts = statusLine.components(separatedBy: " ").filter { !$0.isEmpty }
        guard parts.count >= 3, let code = Int(parts[1]) else { return }
        FileHandle.safeStderrWrite(
            "[RTSPClient] response \(code) for \(lastSentMethod)\n"
                .data(using: .utf8)!)

        // Parse headers do dictionary (case-insensitive keys). WWW-Authenticate
        // může mít víc duplicate řádků (multi-scheme: Basic + Digest MD5 + Digest
        // SHA-256), standardní dict by overwrite — sbíráme do array zvlášť.
        // Vjezd VIGI advertises tři schémy; klient potřebuje vybrat MD5 Digest
        // (firmware-bug compat).
        var headers: [String: String] = [:]
        var wwwAuthChallenges: [String] = []
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if k == "www-authenticate" {
                    wwwAuthChallenges.append(v)
                } else {
                    headers[k] = v
                }
            }
        }

        // 401 Unauthorized — parse WWW-Authenticate, store challenge, retry stejný request.
        if code == 401, !wwwAuthChallenges.isEmpty {
            // Raw dump všech advertised schémat — užitečné při debug firmware
            // edge cases (vjezd VIGI nabízí Basic + Digest MD5 + Digest SHA-256).
            for raw in wwwAuthChallenges {
                FileHandle.safeStderrWrite(
                    "[RTSPClient] raw www-authenticate: \(raw)\n".data(using: .utf8)!)
            }
            // Vyber preferovaný challenge: MD5 Digest pokud advertised, jinak
            // jakýkoli Digest (DigestAuth.parseChallenge vrací MD5 default pro
            // unrecognized algorithm). Basic schéma skipnem — Digest je vždy
            // preferovaný (Basic posílá password v base64 plaintext).
            let parsed = wwwAuthChallenges.compactMap { DigestAuth.parseChallenge($0) }
            // Preferuj MD5 / MD5-sess explicitně advertised. Pokud žádný MD5,
            // first parsed challenge.
            let challenge = parsed.first(where: { $0.algorithm == .md5 || $0.algorithm == .md5sess })
                            ?? parsed.first
            guard let challenge = challenge else {
                FileHandle.safeStderrWrite(
                    "[RTSPClient] no parseable Digest challenge among \(wwwAuthChallenges.count) headers\n"
                        .data(using: .utf8)!)
                handleError("401 challenge unparseable")
                return
            }
            digestChallenge = challenge
            nonceCounter = 0
            FileHandle.safeStderrWrite(
                "[RTSPClient] digest challenge picked: realm=\(challenge.realm) algorithm=\(challenge.algorithm.rawValue) qop=\(challenge.qop ?? "none") opaque=\(challenge.opaque ?? "none") (z \(parsed.count) parseable / \(wwwAuthChallenges.count) total)\n"
                    .data(using: .utf8)!)
            // Retry exact same method+URL s originálními headery (Accept / Transport
            // apod.) — bez nich VIGI vrátí 406/461 a connect zamrzne.
            let prevHeaders = lastSentHeaders.filter { $0.key != "CSeq" && $0.key != "User-Agent" && $0.key != "Authorization" }
            sendRequest(method: lastSentMethod, url: lastSentURL, headers: prevHeaders)
            return
        }

        guard code == 200 else {
            // Dump hlavičkový blok pro diagnostiku — bez něj by error byl neřešitelný
            // (406 = Accept nesedí, 461 = Transport odmítnut, 454 = Session invalid atd.).
            FileHandle.safeStderrWrite(
                "[RTSPClient] \(lastSentMethod) → \(code) response headers:\n\(header)---END HEADERS---\n"
                    .data(using: .utf8)!)
            handleError("RTSP \(code) \(parts.dropFirst(2).joined(separator: " "))")
            return
        }

        // Session header (z SETUP / PLAY). Audit fix #6: parse `;timeout=N` a použij
        // N/2 jako keepalive interval. Bez tohoto při serveru s `timeout=10` by náš
        // hardcoded 25 s keepalive přišel až po expiraci → `454 Session Not Found`.
        if let session = headers["session"] {
            let parts = session.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
            sessionId = parts.first
            for p in parts.dropFirst() {
                let lower = p.lowercased()
                if lower.hasPrefix("timeout=") {
                    let v = String(p.dropFirst("timeout=".count)).trimmingCharacters(in: .whitespaces)
                    if let secs = TimeInterval(v), secs >= 10 {
                        // N/2 s floor 10 s (ochrana před spam při timeout=10)
                        keepaliveInterval = max(10.0, secs / 2.0)
                        FileHandle.safeStderrWrite(
                            "[RTSPClient] Session timeout=\(secs)s → keepalive every \(keepaliveInterval)s\n"
                                .data(using: .utf8)!)
                    }
                }
            }
        }

        // Routovat podle metody co odpovídá danému response (lastSentMethod)
        switch lastSentMethod {
        case "DESCRIBE":
            guard !body.isEmpty else {
                handleError("DESCRIBE 200 ale body prázdné — server pravděpodobně nečeká SDP (chybí Accept header v retry?)")
                return
            }
            guard let sdpText = String(data: body, encoding: .utf8) else {
                handleError("SDP decode failed (body=\(body.count) B)")
                return
            }
            // Dump prvních 512 B SDP — šetří hodiny debugu, když parser nebo
            // decoder odmítne stream (chybí sprop-*, jiný codec, …). Plný
            // dump je až při parse chybě níže.
            let preview = sdpText.prefix(512)
            FileHandle.safeStderrWrite(
                "[RTSPClient] DESCRIBE OK body=\(body.count) B preview:\n\(preview)\n---END SDP PREVIEW---\n"
                    .data(using: .utf8)!)
            do {
                let parsed = try SDPParser.parse(sdpText)
                self.sdp = parsed
                onSDPReceived?(parsed)
                sendSetup(controlURL: trackControlURL(parsed.videoControlPath))
            } catch {
                FileHandle.safeStderrWrite(
                    "[RTSPClient] SDP body (\(body.count) B):\n\(sdpText)\n---END SDP---\n"
                        .data(using: .utf8)!)
                handleError("SDP parse: \(error)")
            }
        case "SETUP":
            sendPlay()
        case "PLAY":
            state = .playing
            lastRTPTimestamp = Date()  // start watchdog s čerstvým timestampem
            startKeepalive()
            startWatchdog()
        case "OPTIONS", "TEARDOWN":
            break  // keepalive / cleanup, no action needed
        default: break
        }
    }

    private func trackControlURL(_ control: String) -> String {
        // Control může být absolute URL nebo relative path. Pokud absolute, použij.
        if control.hasPrefix("rtsp://") {
            return control
        }
        // Relative — append k base URL.
        if setupURL.hasSuffix("/") {
            return setupURL + control
        }
        return setupURL + "/" + control
    }

    // MARK: - Digest auth (delegates to DigestAuth helper, RFC 2617 / RFC 7616)

    /// Build `Authorization: Digest ...` header pro daný request (method + URL).
    /// Vrátí nil pokud chybí credentials nebo se klient ještě nedostal k 401 challenge.
    private func buildAuthHeader(method: String, url: String) -> String? {
        guard let user = username, let pass = password,
              let challenge = digestChallenge else { return nil }
        nonceCounter += 1
        let cnonce = DigestAuth.generateCnonce()
        return DigestAuth.buildAuthorizationHeader(
            challenge: challenge,
            username: user,
            password: pass,
            method: method,
            uri: url,
            nonceCount: nonceCounter,
            cnonce: cnonce
        )
    }

    // MARK: - Keepalive + Watchdog

    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Audit fix #6: použij server-advertised interval (defaultuje na 25 s).
        let interval = keepaliveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.sendOptions() }
        timer.resume()
        keepaliveTimer = timer
        FileHandle.safeStderrWrite(
            "[RTSPClient] keepalive started (every \(interval)s)\n".data(using: .utf8)!)
    }

    private func startWatchdog() {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(self.lastRTPTimestamp)
            if elapsed > self.rtpStallTimeout {
                self.handleError("RTP stall \(Int(elapsed))s — no packets received")
            }
        }
        timer.resume()
        watchdogTimer = timer
    }
}

