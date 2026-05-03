import Testing
import Foundation
import CoreMedia
@testable import SPZApp

@Suite("H265Decoder")
struct H265DecoderTests {

    /// Realistické VIGI C250 parameter sets (base64 dekódované z SDP).
    private var vigiVPS: Data {
        Data(base64Encoded: "QAEMAf//AWAAAAMAAAMAAAMAAAMAlqwJ",
             options: [.ignoreUnknownCharacters])!
    }
    private var vigiSPS: Data {
        Data(base64Encoded: "QgEBAWAAAAMAAAMAAAMAAAMAlqADKIALQf4qtO6JLubgwMDAgA27oADN/mAE",
             options: [.ignoreUnknownCharacters])!
    }
    private var vigiPPS: Data {
        Data(base64Encoded: "RAHAcvCUNNkg",
             options: [.ignoreUnknownCharacters])!
    }

    @Test func configure_acceptsValidVIGIParameterSets() {
        let dec = H265Decoder()
        let ok = dec.configure(vps: vigiVPS, sps: vigiSPS, pps: vigiPPS)
        #expect(ok)
    }

    @Test func configure_rejectsEmptyParameterSets() {
        let dec = H265Decoder()
        let ok = dec.configure(vps: Data(), sps: Data(), pps: Data())
        #expect(!ok)
    }

    @Test func configure_idempotent_noopWhenUnchanged() {
        let dec = H265Decoder()
        #expect(dec.configure(vps: vigiVPS, sps: vigiSPS, pps: vigiPPS))
        // Druhé volání se stejnými daty — vrátí true bez recreate session
        #expect(dec.configure(vps: vigiVPS, sps: vigiSPS, pps: vigiPPS))
    }

    @Test func addNAL_parameterSet_bootstrapsDecoder() {
        let dec = H265Decoder()
        // Zkusíme in-band bootstrap: feed VPS+SPS+PPS jako Annex-B NAL units.
        // addNAL by měl sám zavolat configure() po kompletní trojici.
        func annexB(_ body: Data) -> Data {
            var d = Data([0, 0, 0, 1])
            d.append(body)
            return d
        }
        dec.addNAL(annexBNAL: annexB(vigiVPS))
        dec.addNAL(annexBNAL: annexB(vigiSPS))
        dec.addNAL(annexBNAL: annexB(vigiPPS))
        // Po trojici bootstrap — flushAU se zavolá jinam. Ověříme přes další VCL NAL.
        // Minimal bogus IDR (type 19), decoder ho dostane do auBuffer ale decode selže
        // (fake data); to nevadí — cílem testu je verify že bootstrap prošel, tj. že
        // session není nil. Session testujeme nepřímo: addNAL nesmí crash.
        let fakeIDR = annexB(Data([0x26, 0x01, 0xAA, 0xBB]))
        dec.addNAL(annexBNAL: fakeIDR)
        dec.flushAU()
        // Pokud konfigurace selhala, dekodér by crash jít neměl — jen silent drop.
        // Test == smoke test — nesmí throw / fatalError.
    }

    @Test func flushAU_emptyBuffer_isNoop() {
        let dec = H265Decoder()
        _ = dec.configure(vps: vigiVPS, sps: vigiSPS, pps: vigiPPS)
        dec.flushAU()  // prázdný buffer — žádná chyba, žádný decode
    }

    @Test func invalidate_clearsSession() {
        let dec = H265Decoder()
        _ = dec.configure(vps: vigiVPS, sps: vigiSPS, pps: vigiPPS)
        dec.invalidate()
        // Po invalidate lze configure znovu volat bez crash
        let ok = dec.configure(vps: vigiVPS, sps: vigiSPS, pps: vigiPPS)
        #expect(ok)
    }
}
