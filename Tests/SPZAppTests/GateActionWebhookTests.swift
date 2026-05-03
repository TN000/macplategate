import Foundation
import Testing
@testable import SPZApp

/// Test scenario routing pro Shelly Pro 1 — `WebhookClient.buildShellyURL`
/// musí postavit správný `Switch.Set` URL pro každý `GateAction`. Reálné HTTP
/// fire není testovaný (jen URL builder + GateActionConfig respektování).
struct GateActionWebhookTests {
    @Test func buildShellyURL_openShort_baseOnly() {
        let cfg = GateActionConfig(pulseShortSec: 1.0, pulseExtendedSec: 20.0, keepAliveBeatSec: 2.0)
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163",
                                                action: .openShort, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=1")
    }

    @Test func buildShellyURL_openShort_baseTrailingSlash() {
        let cfg = GateActionConfig.defaults
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163/",
                                                action: .openShort, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=1")
    }

    @Test func buildShellyURL_openShort_baseWithFullPath() {
        let cfg = GateActionConfig.defaults
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163/rpc/Switch.Set",
                                                action: .openShort, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=1")
    }

    @Test func buildShellyURL_openShort_stripsExistingQuery() {
        let cfg = GateActionConfig.defaults
        let url = WebhookClient.buildShellyURL(
            baseURL: "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=99",
            action: .openShort, config: cfg)
        // Existing query je strip-nutý — scenario routing si dělá vlastní.
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=1")
    }

    @Test func buildShellyURL_openExtended_usesPulseExtendedSec() {
        let cfg = GateActionConfig(pulseShortSec: 1.0, pulseExtendedSec: 20.0, keepAliveBeatSec: 2.0)
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163",
                                                action: .openExtended, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=20")
    }

    @Test func buildShellyURL_openHoldStart_noToggleAfter() {
        let cfg = GateActionConfig.defaults
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163",
                                                action: .openHoldStart, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true")
    }

    @Test func buildShellyURL_openHoldBeat_usesKeepAliveBeatSec() {
        let cfg = GateActionConfig(pulseShortSec: 1.0, pulseExtendedSec: 20.0, keepAliveBeatSec: 3.0)
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163",
                                                action: .openHoldBeat, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=3")
    }

    @Test func buildShellyURL_closeRelease() {
        let cfg = GateActionConfig.defaults
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163",
                                                action: .closeRelease, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=false")
    }

    @Test func buildShellyURL_emptyBase_returnsNil() {
        let url = WebhookClient.buildShellyURL(baseURL: "",
                                                action: .openShort, config: .defaults)
        #expect(url == nil)
    }

    @Test func buildShellyURL_whitespaceBase_returnsNil() {
        let url = WebhookClient.buildShellyURL(baseURL: "   ",
                                                action: .openShort, config: .defaults)
        #expect(url == nil)
    }

    @Test func gateActionAuditTag_distinct() {
        // Pro audit log + rate limit klíč potřebujeme distinct tagy.
        let tags: [String: GateAction] = [
            "openShort": .openShort,
            "openExtended": .openExtended,
            "openHoldStart": .openHoldStart,
            "openHoldBeat": .openHoldBeat,
            "closeRelease": .closeRelease
        ]
        for (tag, action) in tags {
            #expect(action.auditTag == tag)
        }
        #expect(Set(tags.keys).count == 5)
    }

    @Test func formatSec_floatPulse() {
        // Float pulse 2.5 s by měl vyrobit "2.50" (ne "2"). Edge case pro
        // sub-second pulse přes Shelly script (v default config nepoužité).
        let cfg = GateActionConfig(pulseShortSec: 2.5, pulseExtendedSec: 20.0, keepAliveBeatSec: 2.0)
        let url = WebhookClient.buildShellyURL(baseURL: "http://192.0.2.163",
                                                action: .openShort, config: cfg)
        #expect(url == "http://192.0.2.163/rpc/Switch.Set?id=0&on=true&toggle_after=2.50")
    }
}
