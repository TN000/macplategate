import Testing
import Foundation
@testable import SPZApp

// MARK: - Mock resolver

/// Test-only DNS resolver — returns fixed list. Žádný real network call.
final class MockResolver: HostResolverBackend, @unchecked Sendable {
    var responses: [String: [Data]] = [:]
    var resolveError: Error? = nil

    func resolve(_ host: String) async throws -> [Data] {
        if let err = resolveError { throw err }
        return responses[host.lowercased()] ?? []
    }

    /// Helper — IPv4 string → 4-byte Data (network order).
    static func ipv4(_ s: String) -> Data {
        let parts = s.split(separator: ".").compactMap { UInt8($0) }
        return Data(parts)
    }
}

// MARK: - WebhookValidator (SSRF guard) tests

@Suite("WebhookValidator")
struct WebhookValidatorTests {

    @Test func ipv4LiteralLoopbackRejected() async {
        let mock = MockResolver()
        let result = await WebhookValidator.checkHost("127.0.0.1", resolver: mock)
        guard case .rejected = result else {
            Issue.record("expected rejected, got \(result)")
            return
        }
    }

    @Test func ipv4LiteralLanAccepted() async {
        // RFC1918 — Shelly lives here, must NOT be blocked.
        let mock = MockResolver()
        let r1 = await WebhookValidator.checkHost("192.168.1.50", resolver: mock)
        let r2 = await WebhookValidator.checkHost("10.0.0.5", resolver: mock)
        let r3 = await WebhookValidator.checkHost("172.16.5.10", resolver: mock)
        if case .rejected = r1 { Issue.record("192.168.1.50 unexpectedly rejected") }
        if case .rejected = r2 { Issue.record("10.0.0.5 unexpectedly rejected") }
        if case .rejected = r3 { Issue.record("172.16.5.10 unexpectedly rejected") }
    }

    @Test func ipv4LiteralLinkLocalRejected() async {
        let mock = MockResolver()
        // AWS metadata 169.254.169.254 — classic SSRF target.
        let r = await WebhookValidator.checkHost("169.254.169.254", resolver: mock)
        guard case .rejected = r else { Issue.record("link-local NOT rejected"); return }
    }

    @Test func ipv4LiteralMulticastRejected() async {
        let mock = MockResolver()
        let r = await WebhookValidator.checkHost("224.1.2.3", resolver: mock)
        guard case .rejected = r else { Issue.record("multicast NOT rejected"); return }
    }

    @Test func ipv6LiteralLoopbackRejected() async {
        let mock = MockResolver()
        let r = await WebhookValidator.checkHost("::1", resolver: mock)
        guard case .rejected = r else { Issue.record("::1 NOT rejected"); return }
    }

    @Test func ipv6LiteralLinkLocalRejected() async {
        let mock = MockResolver()
        let r = await WebhookValidator.checkHost("fe80::1", resolver: mock)
        guard case .rejected = r else { Issue.record("fe80:: NOT rejected"); return }
    }

    @Test func localhostHostnameRejected() async {
        let mock = MockResolver()
        let r = await WebhookValidator.checkHost("localhost", resolver: mock)
        guard case .rejected = r else { Issue.record("localhost NOT rejected"); return }
    }

    @Test func dnsResolvesToLoopback_rejected() async {
        // DNS rebinding scenario — hostname resolves to 127.0.0.1.
        let mock = MockResolver()
        mock.responses["evil.example.com"] = [MockResolver.ipv4("127.0.0.1")]
        let r = await WebhookValidator.checkHost("evil.example.com", resolver: mock)
        guard case .rejected(let reason) = r else {
            Issue.record("evil.example.com → 127.0.0.1 NOT rejected")
            return
        }
        #expect(reason.contains("127.0.0.1") || reason.contains("reserved"))
    }

    @Test func dnsResolvesToLan_accepted() async {
        let mock = MockResolver()
        mock.responses["shelly.local"] = [MockResolver.ipv4("192.168.1.50")]
        let r = await WebhookValidator.checkHost("shelly.local", resolver: mock)
        if case .rejected = r { Issue.record("shelly.local → 192.168.1.50 unexpectedly rejected") }
    }

    @Test func dnsResolvesEmpty_rejected() async {
        let mock = MockResolver()
        mock.responses["nx.example.com"] = []
        let r = await WebhookValidator.checkHost("nx.example.com", resolver: mock)
        guard case .rejected = r else { Issue.record("empty DNS NOT rejected"); return }
    }

    @Test func dnsAnyIpReserved_rejected() async {
        // Server vrátí mix valid + reserved IP — strict reject.
        let mock = MockResolver()
        mock.responses["mixed.example.com"] = [
            MockResolver.ipv4("192.168.1.50"),
            MockResolver.ipv4("127.0.0.1"),
        ]
        let r = await WebhookValidator.checkHost("mixed.example.com", resolver: mock)
        guard case .rejected = r else {
            Issue.record("mixed DNS s loopback NOT rejected")
            return
        }
    }

    // MARK: IP literal parsing primitives

    @Test func parseIPv4_validForms() {
        #expect(WebhookValidator.parseIPv4("0.0.0.0") != nil)
        #expect(WebhookValidator.parseIPv4("192.168.1.50") != nil)
        #expect(WebhookValidator.parseIPv4("255.255.255.255") != nil)
    }

    @Test func parseIPv4_invalidFormsRejected() {
        #expect(WebhookValidator.parseIPv4("256.0.0.1") == nil)
        #expect(WebhookValidator.parseIPv4("not.an.ip") == nil)
        #expect(WebhookValidator.parseIPv4("192.168.1") == nil)
    }

    @Test func parseIPv6_validForms() {
        #expect(WebhookValidator.parseIPv6("::1") != nil)
        #expect(WebhookValidator.parseIPv6("fe80::1") != nil)
        #expect(WebhookValidator.parseIPv6("2001:db8::1") != nil)
    }
}

// MARK: - WebhookClient async fire tests

@MainActor
@Suite("WebhookClientAsyncFire")
struct WebhookClientAsyncFireTests {

    private func makeClient(resolver: HostResolverBackend = MockResolver()) -> WebhookClient {
        WebhookClient(resolver: resolver)
    }

    /// fireOnce s loopback IP literálem → SSRF reject bez network call.
    @Test func fireOnceRejectsLoopbackLiteral() async {
        let result = await makeClient().fireOnce(
            url: "http://127.0.0.1:8080/relay", plate: "TEST", camera: "test",
            eventId: "TEST-\(UUID().uuidString)", timeout: 1.0
        )
        guard case .rejectedBySSRF = result else {
            Issue.record("expected rejectedBySSRF for 127.0.0.1, got \(result)")
            return
        }
    }

    @Test func fireOnceRejectsHostnameThatResolvesToReserved() async {
        let mock = MockResolver()
        mock.responses["evil.example.com"] = [MockResolver.ipv4("169.254.169.254")]
        let result = await makeClient(resolver: mock).fireOnce(
            url: "http://evil.example.com/x", plate: "T", camera: "c",
            eventId: "T-\(UUID().uuidString)", timeout: 1.0
        )
        guard case .rejectedBySSRF = result else {
            Issue.record("DNS to AWS metadata range should be rejected, got \(result)")
            return
        }
    }

    @Test func fireOnceRejectsNonHTTPScheme() async {
        let result = await makeClient().fireOnce(
            url: "ftp://example.com/relay", plate: "T", camera: "c",
            eventId: "T-\(UUID().uuidString)", timeout: 1.0
        )
        guard case .rejectedBySSRF = result else {
            Issue.record("non-http scheme should be rejected, got \(result)")
            return
        }
    }

    @Test func fireOnceRejectsEmptyURL() async {
        let result = await makeClient().fireOnce(
            url: "", plate: "T", camera: "c",
            eventId: "T-\(UUID().uuidString)", timeout: 1.0
        )
        guard case .rejectedBySSRF = result else {
            Issue.record("empty URL should be rejected, got \(result)")
            return
        }
    }

    /// fireOnce → unreachable LAN IP. Mock resolver propustí, URLSession se
    /// pokusí a krátký timeout způsobí networkError. Ověřuje že timeout
    /// path funguje a vrátí .networkError ne hang.
    @Test func fireOnceTimesOutOnUnreachableHost() async {
        let mock = MockResolver()
        // 192.0.2.0/24 = TEST-NET-1 (RFC 5737) — guaranteed to not respond.
        mock.responses["unreachable.test"] = [MockResolver.ipv4("192.0.2.123")]
        let client = makeClient(resolver: mock)
        let start = Date()
        let result = await client.fireOnce(
            url: "http://unreachable.test/relay", plate: "T", camera: "c",
            eventId: "T-\(UUID().uuidString)", timeout: 0.5
        )
        let elapsed = Date().timeIntervalSince(start)
        guard case .networkError = result else {
            Issue.record("expected networkError on timeout, got \(result)")
            return
        }
        // Timeout 0.5 s, allow up to 3 s for OS retry/teardown. Žádný hang > 5 s.
        #expect(elapsed < 5.0, "fireOnce hung \(elapsed)s")
    }

    /// Rate limit: dva nové fireOnce events pro stejnou URL/SPZ v rychlém sledu
    /// musí druhý zablokovat i když má jiný eventId. Retry se řeší mimo tento
    /// test přes `attempt > 1`.
    @Test func rateLimitUsesStableUrlPlateKey() async {
        let mock = MockResolver()
        // Použijeme TEST-NET IP aby request rovnou time-outoval (rate-limit
        // path se vyhodnotí PŘED fire). Druhý call musí skončit rateLimited.
        mock.responses["test.local"] = [MockResolver.ipv4("192.0.2.99")]
        let client = makeClient(resolver: mock)

        let r1 = await client.fireOnce(
            url: "http://test.local/r", plate: "T", camera: "c",
            eventId: "EVENT-A-\(UUID().uuidString)", timeout: 0.3
        )
        let r2 = await client.fireOnce(
            url: "http://test.local/r", plate: "T", camera: "c",
            eventId: "EVENT-B-\(UUID().uuidString)", timeout: 0.3
        )
        if case .rateLimited = r1 {
            Issue.record("first call should not be rate-limited")
        }
        guard case .rateLimited = r2 else {
            Issue.record("second duplicate event should be rate-limited, got \(r2)")
            return
        }
    }
}
