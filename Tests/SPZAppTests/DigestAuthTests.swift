import Testing
import Foundation
@testable import SPZApp

@Suite("DigestAuth")
struct DigestAuthTests {

    // MARK: - Parser

    @Test func parsesBasicChallenge() {
        let header = #"Digest realm="testrealm@host.com", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", qop="auth", opaque="5ccc069c403ebaf9f0171e9517f40e41""#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.realm == "testrealm@host.com")
        #expect(c?.nonce == "dcd98b7102dd2f0e8b11d0f600bfb0c093")
        #expect(c?.qop == "auth")
        #expect(c?.opaque == "5ccc069c403ebaf9f0171e9517f40e41")
        #expect(c?.algorithm == .md5)  // default RFC 2617
    }

    @Test func parsesQuotedCommaInQop() {
        // qop="auth,auth-int" — čárka uvnitř quoted string nesmí rozdělit pair.
        let header = #"Digest realm="x", nonce="abc", qop="auth,auth-int""#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.qop == "auth,auth-int")
    }

    @Test func parsesAlgorithmSHA256SoloDefaultsToMD5() {
        // VIGI C250 firmware-bug accommodation: kamera advertises SHA-256 ale
        // server-side check expects MD5. Parser vrací MD5 i pro single SHA-256
        // advertise. SHA-256 implementace zůstává v computeResponse pro future
        // manual override.
        let header = #"Digest realm="x", nonce="abc", qop="auth", algorithm=SHA-256"#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.algorithm == .md5)
    }

    @Test func parsesAlgorithmMD5Sess() {
        // MD5-sess explicitly advertised — to respektujeme (sess je MD5 family,
        // ne known-broken kombinace).
        let header = #"Digest realm="x", nonce="abc", algorithm=MD5-sess"#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.algorithm == .md5sess)
    }

    @Test func parsesMultiAlgoOfferPicksMD5() {
        // Server nabízí oba — klient preferuje MD5 (pragmatic firmware compat).
        let header = #"Digest realm="x", nonce="abc", qop="auth", algorithm="SHA-256, MD5""#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.algorithm == .md5)
    }

    @Test func parsesLegacyChallengeWithoutQop() {
        // RFC 2069 — žádné qop. Helper musí vrátit qop=nil.
        let header = #"Digest realm="x", nonce="abc""#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.qop == nil)
        #expect(c?.algorithm == .md5)
    }

    @Test func parsesMultiSchemeHeaderPicksDigest() {
        // Server nabízí Basic + Digest — klient pick Digest.
        let header = #"Basic realm="basic-realm", Digest realm="digest-realm", nonce="xyz""#
        let c = DigestAuth.parseChallenge(header)
        #expect(c?.realm == "digest-realm")
        #expect(c?.nonce == "xyz")
    }

    @Test func returnsNilForMissingFields() {
        // Žádný realm → invalid challenge.
        let header = #"Digest nonce="abc""#
        #expect(DigestAuth.parseChallenge(header) == nil)
    }

    // MARK: - Response computation (RFC 2617 + RFC 7616 sample vectors)

    @Test func md5ResponseMatchesRFC2617() {
        // RFC 2617 § 3.5 example.
        let challenge = DigestAuth.Challenge(
            realm: "testrealm@host.com",
            nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            qop: "auth",
            opaque: "5ccc069c403ebaf9f0171e9517f40e41",
            algorithm: .md5
        )
        let response = DigestAuth.computeResponse(
            challenge: challenge,
            username: "Mufasa",
            password: "Circle Of Life",
            method: "GET",
            uri: "/dir/index.html",
            nonceCount: 1,
            cnonce: "0a4f113b"
        )
        // Spec expected: 6629fae49393a05397450978507c4ef1
        #expect(response == "6629fae49393a05397450978507c4ef1")
    }

    @Test func sha256ResponseMatchesRFC7616() {
        // RFC 7616 § 3.9.1 example (SHA-256 variant).
        let challenge = DigestAuth.Challenge(
            realm: "http-auth@example.org",
            nonce: "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v",
            qop: "auth",
            opaque: "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS",
            algorithm: .sha256
        )
        let response = DigestAuth.computeResponse(
            challenge: challenge,
            username: "Mufasa",
            password: "Circle of Life",
            method: "GET",
            uri: "/dir/index.html",
            nonceCount: 1,
            cnonce: "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"
        )
        // RFC 7616 expected: 753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1
        #expect(response == "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1")
    }

    @Test func legacyResponseWithoutQop() {
        // RFC 2069 path — qop=nil. KD redukuje na H(HA1:nonce:HA2).
        let challenge = DigestAuth.Challenge(
            realm: "test", nonce: "abc123", qop: nil, opaque: nil, algorithm: .md5
        )
        let r1 = DigestAuth.computeResponse(
            challenge: challenge,
            username: "user", password: "pass",
            method: "GET", uri: "/path",
            nonceCount: 1, cnonce: "ignored"
        )
        // Manuální výpočet: HA1 = MD5("user:test:pass"), HA2 = MD5("GET:/path"),
        // response = MD5("\(HA1):abc123:\(HA2)")
        let ha1 = "user:test:pass".md5Hex
        let ha2 = "GET:/path".md5Hex
        let expected = "\(ha1):abc123:\(ha2)".md5Hex
        #expect(r1 == expected)
    }

    @Test func responseDiffersWithDifferentNonceCount() {
        let challenge = DigestAuth.Challenge(
            realm: "x", nonce: "n", qop: "auth", opaque: nil, algorithm: .md5
        )
        let r1 = DigestAuth.computeResponse(
            challenge: challenge, username: "u", password: "p",
            method: "GET", uri: "/", nonceCount: 1, cnonce: "c1"
        )
        let r2 = DigestAuth.computeResponse(
            challenge: challenge, username: "u", password: "p",
            method: "GET", uri: "/", nonceCount: 2, cnonce: "c1"
        )
        #expect(r1 != r2)
    }

    // MARK: - Authorization header

    @Test func authHeaderDefaultDoesNotEchoAlgorithmOpaque() {
        // Některé VIGI C250 firmware odmítnou request s algorithm= nebo opaque=
        // v Authorization, i když je v challenge poslaly. Default
        // `echoAlgorithmOpaque: false` proto nikdy nepřidá ani jedno.
        let challenge = DigestAuth.Challenge(
            realm: "r", nonce: "n", qop: "auth", opaque: "op-12345", algorithm: .sha256
        )
        let header = DigestAuth.buildAuthorizationHeader(
            challenge: challenge, username: "u", password: "p",
            method: "GET", uri: "/", nonceCount: 1, cnonce: "c"
        )
        #expect(!header.contains("algorithm="))
        #expect(!header.contains("opaque="))
        #expect(header.contains("qop=auth"))
        #expect(header.contains("nc=00000001"))
        #expect(header.contains("cnonce=\"c\""))
    }

    @Test func authHeaderEchoesAlgorithmOpaqueWhenOptedIn() {
        // Strict RFC 7616 mode pro budoucí non-VIGI klienty.
        let challenge = DigestAuth.Challenge(
            realm: "r", nonce: "n", qop: "auth", opaque: "op-1", algorithm: .sha256
        )
        let header = DigestAuth.buildAuthorizationHeader(
            challenge: challenge, username: "u", password: "p",
            method: "GET", uri: "/", nonceCount: 1, cnonce: "c",
            echoAlgorithmOpaque: true
        )
        #expect(header.contains("algorithm=SHA-256"))
        #expect(header.contains("opaque=\"op-1\""))
    }

    @Test func authHeaderOmitsQopFieldsWhenChallengeQopNil() {
        // Legacy challenge → response bez qop/nc/cnonce v Authorization headeru.
        let challenge = DigestAuth.Challenge(
            realm: "r", nonce: "n", qop: nil, opaque: nil, algorithm: .md5
        )
        let header = DigestAuth.buildAuthorizationHeader(
            challenge: challenge, username: "u", password: "p",
            method: "GET", uri: "/", nonceCount: 1, cnonce: "c"
        )
        #expect(!header.contains("qop="))
        #expect(!header.contains("nc="))
        #expect(!header.contains("cnonce="))
    }

    // MARK: - cnonce generator

    @Test func cnonceIsHex16() {
        let c = DigestAuth.generateCnonce()
        #expect(c.count == 16)
        #expect(c.allSatisfy { $0.isHexDigit })
    }

    @Test func cnonceVariesAcrossCalls() {
        // Velmi nízká pravděpodobnost kolize na 64-bit randomness.
        let s = Set((0..<10).map { _ in DigestAuth.generateCnonce() })
        #expect(s.count == 10)
    }
}

// MARK: - Test helpers

private extension String {
    /// Lokální MD5 hex pro test expectations (musí matchnout DigestAuth.Algorithm.md5.hash).
    var md5Hex: String {
        DigestAuth.Algorithm.md5.hash(self)
    }
}
