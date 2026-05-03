// PlateTransform.metal — fused NV12 sampling + homography warp + BGRA output.
//
// Vstup:
//   - yPlane: NV12 Y plane (1 B/px luminance) jako texture2d<float>
//   - uvPlane: NV12 interleaved UV plane (half-res chroma) jako texture2d<float>
//   - homography: inverse 3x3 matrix mapping destination[gid] → source[srcCoord]
//                 Produkuje se na Swift straně z ROI crop + rotation + perspective
//                 + detectionQuad crop zřetězených do jedné matice.
//   - outputBGRA: cílová textura (BGRA8Unorm), dimenze = canonical plate-sized
//
// Výstup:
//   outputBGRA obsahuje rovnaný / perspective-correction-applied plate region,
//   ready to hand to Vision VNRecognizeTextRequest (přes CGImage conversion).
//
// BT.709 YCbCr (video range) → RGB conversion je inline. Kamera VIGI C250 produkuje
// HEVC v BT.709; VT decoder vrací raw video-range values, color-space convert musíme
// udělat manuálně.

#include <metal_stdlib>
using namespace metal;

// NV12 Video Range → RGB (BT.709) — per ITU-R BT.709
// Y ∈ [16/255, 235/255], CbCr ∈ [16/255, 240/255], with bias 128/255 on chroma.
// RGB = BT709_MATRIX * (YCbCr - bias) * gain

static inline float3 ycbcr_videoRange_to_rgb_bt709(float y, float cb, float cr) {
    // Normalize video range → full range
    float yN = (y - 16.0/255.0) * (255.0/219.0);
    float cbN = (cb - 128.0/255.0) * (255.0/224.0);
    float crN = (cr - 128.0/255.0) * (255.0/224.0);
    // BT.709 conversion
    float r = yN                + 1.5748 * crN;
    float g = yN - 0.1873 * cbN - 0.4681 * crN;
    float b = yN + 1.8556 * cbN;
    return clamp(float3(r, g, b), 0.0, 1.0);
}

kernel void plateTransform(
    texture2d<float, access::sample> yPlane   [[texture(0)]],
    texture2d<float, access::sample> uvPlane  [[texture(1)]],
    texture2d<float, access::write>  outputBGRA [[texture(2)]],
    constant float3x3               &homography [[buffer(0)]],
    uint2                           gid [[thread_position_in_grid]]
) {
    uint outW = outputBGRA.get_width();
    uint outH = outputBGRA.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    // Destination coord → source pixel coord via inverse homography
    float3 srcHom = homography * float3(float(gid.x), float(gid.y), 1.0);
    float2 srcCoord = srcHom.xy / srcHom.z;

    // Source plane dimensions (Y plane = full frame for NV12)
    float2 yDim = float2(yPlane.get_width(), yPlane.get_height());
    float2 srcNorm = srcCoord / yDim;

    // Bounds check — out-of-range vyplní černou (ne edge clamp, protože by
    // artifact-ovaly plate okraje do warped výstupu)
    if (any(srcNorm < 0.0) || any(srcNorm > 1.0)) {
        outputBGRA.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    constexpr sampler yuvSampler(
        coord::normalized,
        filter::linear,
        address::clamp_to_edge
    );
    float y = yPlane.sample(yuvSampler, srcNorm).r;
    // UV plane je half-res (W/2 × H/2 samples of Cb,Cr pairs); Metal sampleruje
    // normalized coord → auto interpolace. `rg` = (Cb, Cr) z interleaved NV12.
    float2 uv = uvPlane.sample(yuvSampler, srcNorm).rg;

    float3 rgb = ycbcr_videoRange_to_rgb_bt709(y, uv.x, uv.y);
    // BGRA output — BGR order (Apple display convention). Alpha 1.0.
    outputBGRA.write(float4(rgb.b, rgb.g, rgb.r, 1.0), gid);
}
