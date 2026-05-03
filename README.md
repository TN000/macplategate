# MacPlateGate

**Local macOS gate automation with license plate recognition.**

MacPlateGate recognizes license plates on-device using Apple-native vision pipelines and controls local hardware (Shelly relays driving an automatic gate controller). No cloud, no Linux server, no Docker stack.

Built for small sites that want simple, private ALPR-based access control without enterprise VMS pricing.

---

## What it does

- Pulls H.265 RTSP from one or two IP cameras (entry / exit).
- Runs Apple Vision (`.accurate`, ANE-accelerated) and an optional secondary FastPlateOCR ONNX engine for cross-engine consensus.
- Tracks plates across frames with a 5-layer dedup defense (exact / L1 / L2 / ambiguous-glyph / fragment-prefix).
- On a whitelisted plate, fires a webhook to a Shelly Pro 1 relay that pulses an automatic gate controller (e.g. AG500F).
- Two independent Shelly devices supported (entry and exit), each with its own enable toggle, base URL, Digest auth credentials and pulse durations.
- Includes a local web UI on the LAN (HTTPS, Basic Auth, IP whitelist, brute-force throttling) for manual gate control without leaving your laptop.
- Persists detections to SQLite + JSONL audit log + JPEG snapshots, all on the same Mac.

---

## How it compares

There are three loose tiers of plate-driven access control today:

| Tier | Examples | Per-site cost | Setup effort | Where MacPlateGate fits |
|---|---|---|---|---|
| **Enterprise VMS** | Genetec AutoVu, Vaxtor (on Bosch / Hikvision), Tattile, Survision, Q-Free | $5k–15k+ per camera + servers + per-seat licenses + annual maintenance | Multi-month sales + integration + certification | Below their floor — they don't quote single-gate sites |
| **Cloud / SaaS** | Plate Recognizer, Rekor (former OpenALPR Cloud), CarmenALPR API | $30–250 / camera / month + bandwidth + cloud platform | Low (REST API) but requires upstream + recurring fees | Drop-in replacement, no recurring cost, no cloud round-trip |
| **DIY / OSS** | Frigate + Plate Recognizer plugin, Rekor on-prem, custom YOLO + PaddleOCR | Hardware + many engineer-days | Linux + Docker + NVR + GPU drivers + glue code | Same outcome, single binary, no Linux fleet to maintain |

### Where we are stronger

- **Single-binary native macOS app.** No Docker, no CUDA, no NVR, no separate VMS. Build, codesign (ad-hoc or notarized), copy to `/Applications`, done. The whole stack is `swift build` reproducible.
- **No cloud.** Plates, snapshots and audit log never leave the Mac. GDPR-trivial: data subject access = `~/Library/Application Support/MacPlateGate/` on the host. No third-party processor agreements, no data residency caveats.
- **Cheap hardware floor.** A working production install is a Mac mini M4 (~$600) + an IP camera (€30–€300 depending on choice) + a Shelly Pro 1 (€80). Enterprise systems start north of $5,000 just for one camera channel.
- **ANE-accelerated OCR for free.** Apple Vision `.accurate` runs on the Apple Neural Engine, included in every Apple Silicon Mac. No GPU license, no model fees, no per-image cloud billing. Sub-50 ms per frame on M4.
- **Cross-engine consensus.** Optional secondary FastPlateOCR ONNX engine validates Vision's reading. Disagreements are flagged, agreement upgrades the result to "cross-validated" — a heuristic enterprise systems usually don't expose at all.
- **Production-tuned heuristics.** 5-layer dedup (exact / Levenshtein-1 / Levenshtein-2 / ambiguous-glyph matrix / fragment-prefix), CZ vyhláška-compliant validator (forbidden glyphs G/O/Q/W enforced), CZ Electric (EL/EV) prefix support, vanity plates, foreign DE/IT/ES heuristics. 301 unit tests covering real misread incidents.
- **Low operational footprint.** ~30 MB binary, ~140 MB baseline RAM, ~650 MB peak with two cameras. The Mac mini idles at <5 W; a typical small-gate site draws <30 W under sustained load. No fans spinning, no rack required.
- **You own the source.** AGPL-3.0 for free use, commercial license available for closed bundling. No vendor lock-in, no dead-product risk.

### Where we are weaker

Honest list of things MacPlateGate **does not** do (and probably never will, unless someone needs them and asks):

- **No multi-site / fleet dashboard.** Each install is standalone. If you operate 50 parking lots and want a single pane of glass, this isn't it.
- **No certified tolling or law-enforcement use.** No national plate-DB integration, no court-admissible chain-of-custody, no compliance with regulated tolling standards.
- **No automatic country detection beyond CZ / SK / "foreign generic".** It will read most European plates, but it does not know which country emitted them. Cyrillic, Arabic, Asian scripts are not supported.
- **No specialized models for trucks / motorbikes.** OCR is tuned for standard passenger plates. Tall HGV plates and tiny motorbike plates work, but not as reliably as on dedicated systems.
- **No HA / redundancy out of the box.** One Mac mini = one point of failure. For dual-host failover you'd run two installs and split cameras manually.
- **No vendor SLA in the AGPL version.** Bring-your-own-support unless you take a commercial license.
- **Self-signed TLS for the web UI.** Browsers warn on first visit. A real cert (Let's Encrypt over a tunnel, or an internal CA) requires manual setup.
- **No Windows or Linux build.** This is intentional — the project's value comes from leaning on Apple frameworks. A cross-platform port would lose that advantage.
- **macOS 14+ Apple Silicon only.** Intel Macs are not supported (no ANE).

If any of those are blockers for you, look at Genetec / Vaxtor on the high end, or Plate Recognizer / Frigate-Plus on the low end.

---

## Camera choice — VIGI C250 vs Hikvision

The pipeline takes any RTSP H.265 source with Digest auth, so camera choice is mostly about **image quality at the gate** rather than software compatibility. Two practical options:

### TP-Link VIGI C250 (~€30–60)

- 4 MP H.265 / H.264, RTSP main + sub stream, Digest auth (MD5).
- ONVIF Profile S, PoE.
- IP66, IR up to 30 m.
- What you get for the price is fine for a residential / small-business gate at 3–5 m distance with reasonable lighting.
- Limitations:
  - Sensor is decent but not low-light champion. Plate readability drops at dusk and in heavy rain.
  - Fixed lens. Plate framing is whatever the install angle gives you.
  - Some firmware quirks: the camera advertises SRTP capability but pre-firmware-1.2 builds reject some standard SRTP setups. MacPlateGate uses plain RTP-over-TCP, which avoids the issue entirely.
  - IR illumination is consumer-grade — works but not as crisp as professional cameras at the same distance.

### Hikvision (DS-2CD2xxx generic, ~€80–250) or LPR-specific (iDS-2CD7xxx, €800–1500+)

There are two ways to use Hikvision:

**A) Hikvision as a "better RTSP camera"** (DS-2CD2xxx series, varifocal models like DS-2CD2T87G2-LSU/SL):
- Better sensors (often Sony Starvis, larger pixels) — noticeably better low-light.
- Motorized varifocal lens — you can dial in plate framing without remounting.
- IR illumination is brighter and more even.
- Faster shutter options for fast-moving traffic — fewer motion-blurred frames.
- Mature firmware, stable RTSP, ONVIF Profile S+T, Digest auth, H.265+ support.
- IP67 weatherproofing standard (vs IP66 on VIGI).
- MacPlateGate treats it identically to the VIGI: pull RTSP, decode HEVC, run Vision OCR. The on-camera "smart features" (intrusion / line-cross / vehicle detection) are ignored — we do all detection in software.
- **Net effect on accuracy:** in good daylight the difference is maybe 1–2 percentage points. At dusk, in rain, or with vehicles entering at >20 km/h, Hikvision tends to win by 5–15 percentage points purely because more frames are usable.

**B) Hikvision LPR-specific cameras** (iDS-2CD7A26G0/P-IZHS and similar — built-in LPR):
- The camera does its own plate detection and emits structured plate metadata over Hikvision's proprietary streams (ISAPI / SDK).
- Costs 5–10× a generic Hik camera.
- **MacPlateGate currently does not consume the on-camera LPR metadata.** The camera works fine as a plain RTSP source, but you would be paying for ALPR firmware you're not using. If you already own one of these, it works; if you're buying fresh, the generic Hikvision plus our software gives you the same outcome at half the cost.
- A future version could optionally consume Hikvision LPR metadata as a third validator alongside Vision and FastPlateOCR. Not on the roadmap unless someone asks for it.

### Quick recommendation

| Scenario | Recommended |
|---|---|
| Daytime-only residential gate, simple geometry | VIGI C250 — cheapest, just works |
| Mixed conditions, fast vehicles, dusk operation | Generic Hikvision (DS-2CD2T87G2 class) |
| You already have Hikvision LPR cameras | Use them — MacPlateGate ignores the LPR metadata for now but the RTSP feed is great |
| Deployment with NDAA / federal-procurement constraints | VIGI or Axis (Hikvision is on several government bans) |
| You need third-party certified ALPR for tolling | Don't use MacPlateGate — get Vaxtor or Genetec |

A second camera placed at the **exit** doubles dedup confidence and lets MacPlateGate cross-validate plates on departure even if entry was missed. It is fully optional.

---

## Why a native macOS stack

The architectural decision that defines this project is not "do ALPR" — there are dozens of OSS pipelines that do that. It is "do ALPR **without a Linux box, without a GPU and without Docker**". The Apple platform makes that possible because:

- **Apple Neural Engine.** Vision's `.accurate` OCR runs on the ANE, which every Apple Silicon chip has. It's free and faster than most discrete GPU pipelines for this kind of workload. No CUDA driver, no model conversion, no per-frame inference cost.
- **VideoToolbox** decodes H.265 directly on the media engine — the decoded frame lands in an `IOSurface`-backed `CVPixelBuffer` that Vision and Metal can read with zero copies.
- **Network.framework** speaks RTSP over TCP cleanly; we wrote a 330-line `RTSPClient.swift` (DESCRIBE → SETUP → PLAY, Digest auth, RFC 2326 interleaved transport) and a 200-line RFC 7798 H.265 RTP depacketizer. That replaces FFmpeg + go2rtc + a relay daemon with two Swift files.
- **CoreImage + Metal** handle perspective correction, ROI cropping, NV12 → RGBA conversion in a single GPU pass when you flip the experimental Metal kernel on. The fallback CI pipeline is also fully GPU-resident.
- **AVSampleBufferDisplayLayer** renders the live preview without a copy — the same `CVPixelBuffer` Vision OCR'd is what your eyes see.
- **Power and thermals.** Mac mini M4 idles at <5 W and peaks under 30 W with two cameras at 10 fps detect. Comparable Linux-on-Intel-NUC setups draw 3–5× more for the same throughput, and they need fans.
- **Reliability.** macOS userspace audio/video is one of the most-tested code paths on the planet. Cheap Linux ALPR boxes deal with kernel-driver flakiness, V4L2 quirks, USB capture-card resets. We don't.
- **Distribution.** A signed `.app` bundle. Drag to `/Applications`, run. No `apt`, no `systemd` units, no Python venvs.
- **Reproducible builds.** `swift build -c release` against a vendored `Package.resolved`. The release binary is bit-exact across machines with the same Xcode toolchain.

The trade-off is that the project is **macOS-only**. You cannot run MacPlateGate on a Linux server, a Synology NAS or a Raspberry Pi. That's the cost of leaning on platform features.

---

## Status

- Production-deployed against 2× VIGI C250 cameras + 1× Shelly Pro 1 + AG500F gate controller.
- 301 unit tests covering normalizer, tracker, dedup, webhook, RTSP, HEVC decoder, ambiguous-glyph matrix, and the delayed-drop fragment-match heuristic.
- Single binary, ~30 MB; ~140 MB baseline RAM, ~650 MB peak under 2-camera load.
- macOS 14+ (Sonoma), built for Apple Silicon (`-arch arm64`).

---

## Hardware tested

- **Cameras:** TP-Link VIGI C250 (any RTSP H.265 IP camera with Digest auth should work — Hikvision DS-2CD2xxx, Axis P-series, Dahua IPC-HFW2xxx all viable).
- **Relay:** Shelly Pro 1 (gen 2, firmware 1.7.5+) with potential-free contacts wired in parallel with an existing radio receiver into an automatic gate controller (AG500F STEP/PP terminal). 230 V AC powered. Digest auth supported.
- **Host:** Mac mini M4 (any Apple Silicon Mac running macOS 14+ should work).

The webhook layer speaks Shelly's `/rpc/Switch.Set` API, but the URL builder is generic — anything that closes a contact on an HTTP GET can be wired up.

---

## Install

```bash
git clone https://github.com/TN000/macplategate.git
cd macplategate

# Download the optional FastPlateOCR ONNX model (~3 MB).
# Without it the app runs Vision-only — pipeline still works, accuracy drops slightly.
bash scripts/install_models.sh

# Build a signed (ad-hoc) .app bundle into build/MacPlateGate.app.
bash scripts/build_app.sh

# Or run directly via swift run for development:
swift run -c release
```

First launch creates `~/Library/Application Support/MacPlateGate/` (kept private, perms 0600). All settings, the whitelist, the SQLite DB, audit log, and snapshots live there.

Configure cameras + Shelly devices in **Settings**. The web UI is off by default — turn it on under **Settings → Network**.

---

## Localization

UI is available in **Czech** and **English**. The active language follows the system preference; you can override it in macOS System Settings → Language & Region.

German and Spanish translations are planned for v1.1 once the project sees sustained traction.

---

## License

MacPlateGate is **dual-licensed**:

- **[AGPL-3.0](LICENSE)** for free / open-source use. Modifications you distribute (including network-exposed deployments) must be released under the same license.
- **Commercial license** for organizations that prefer business-friendly terms (closed-source modifications, proprietary bundling, multi-site deployments, vendor-backed support). See [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) for details and contact.

Both versions are functionally identical — there is no feature gating.

---

## Acknowledgements

- **Apple Vision** for the on-device OCR engine (`.accurate` recognition level on the Apple Neural Engine).
- **[FastPlateOCR](https://github.com/ankandrew/fast-plate-ocr)** by Ankandrew for the secondary cross-engine validator (CCT-XS-v2-global-model, MIT licensed).
- **[ONNX Runtime](https://github.com/microsoft/onnxruntime)** for running the secondary OCR model (Microsoft, MIT licensed).
- The open-source ALPR research community — heuristics like ambiguous-glyph matrices, fragment-match dedup, and consensus-style validation come from working through real production incidents on top of decades of published work.
