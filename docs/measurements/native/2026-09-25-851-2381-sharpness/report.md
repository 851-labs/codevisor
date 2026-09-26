# 851-2381: text sharpness against Apple High Performance

Date: 2026-09-25.

- **Host:** tuftlord, Codevisor alpha 1064.
- **Viewer:** this Mac. tuftlord was reached over Tailscale on a different network.
- **Codevisor viewer:** the rig on the native path (HEVC Main 4:4:4).
- **Apple viewer:** Apple Screen Sharing, High Performance.

## Method

1. `card.py` draws a 1400×560 px test card with magenta corner markers. It contains:
   - black text at 14–26 px (7–13 pt at 2×);
   - coloured text on four coloured backgrounds;
   - vertical black 1-px lines, horizontal blue 1-px lines, and a checker patch.
2. Safari on the host shows the card at 700×280 CSS px on the 2× display. That is 1:1 device pixels (`image-rendering: pixelated`), so the card itself is the ground truth.
3. The viewer's window is captured with `screencapture -l` (that window only). `score.py` then:
   - converts the capture from its embedded profile (Display P3) to sRGB;
   - finds the markers and crops the card;
   - scores each region against the card:
     - **SSIM:** luma, 7×7 window;
     - **ΔC:** mean |ΔCb| + |ΔCr|, BT.709, 0–255 scale.
4. For reference, the card run through a simulated 4:2:0 chroma subsampling (2×2 average) is scored the same way.

Both viewers showed the card at exactly 1400×560 px, which is 1:1 with the host. Captures were taken after 6 s or more of stillness.

## Results

| Viewer                           | Black text SSIM | Coloured text SSIM / ΔC   | 1-px lines SSIM / ΔC      |
| -------------------------------- | --------------- | ------------------------- | ------------------------- |
| Codevisor native, 3 frames       | 0.9986–0.9992   | 0.9976–0.9985 / 2.31–2.40 | 0.9999–1.0000 / 0.09–0.13 |
| Apple High Performance, 2 frames | 0.9995          | 0.9985 / 1.43             | 1.0000 / 0.04             |
| Card as 4:2:0 (reference)        | 1.0000          | 0.9940 / 4.62             | 0.9999 / 4.05             |

A third Apple frame came through scaled (781×312 px, not 1:1) and is left out.

- **Sharpness:** Codevisor matches Apple High Performance on text and 1-px detail; luma SSIM is within 0.001.
- **Colour:** full chroma arrives. The colour error on 1-px blue lines is 0.09–0.13, against 4.05 for 4:2:0.
- **The remaining gap is tone, not blur:**
  - Codevisor's flat colours are 2–5 levels darker in the mid-tones. For example, sky blue (0, 150, 255) arrives as (0, 145, 255) against Apple's (0, 151, 255).
  - Colour error at text edges is close: 5.15 for Codevisor against 4.75 for Apple.
  - Capture is tagged Rec. 709, whose transfer curve differs from sRGB in the mid-tones; that is the likely cause (follow-up ticket).

## Notes

- **Ground truth:** `screencapture` on the host doesn't work over SSH (no screen-recording permission), so the card is the truth. On-screen pixels equal the card's (1:1, no resampling). Colour management is undone by the profile conversion: white and black match exactly, and Apple's flat colours land within 1–2 levels.
- **Apple Screen Sharing:** signed in with the password already saved on this Mac. Nothing was typed, and nothing was recorded outside the viewer windows.

## After 851-2398 (alpha 1074)

Two host fixes, re-measured with the same card and scorer:

- **Capture in sRGB** ([#161](https://github.com/851-labs/codevisor/pull/161)). Rec. 709 capture had re-encoded mid-tones (sky blue 150 → 156, measured with `screen-sharing-rig colour-check` on both Macs), and the viewer then showed them 2–5 levels off.
- **The virtual display's 2× mode, selected explicitly** ([#162](https://github.com/851-labs/codevisor/pull/162)). WindowServer had restored a remembered 1× mode for the product's display, halving text sharpness.

| Viewer                                 | Black text SSIM | Coloured text SSIM / ΔC | 1-px lines SSIM / ΔC |
| -------------------------------------- | --------------- | ----------------------- | -------------------- |
| Codevisor native, alpha 1074, 3 frames | 0.9981          | 0.9973 / **1.26**       | 0.9999 / 0.16        |
| Apple High Performance (above)         | 0.9995          | 0.9985 / 1.43           | 1.0000 / 0.04        |

- The virtual display ran at 2× (880×708 pt, 1760×1416 px), and the card arrived 1:1.
- Flat colours are exact: sky blue (0, 150, 255) arrives as (0, 150, 255).
- Colour error on coloured text is now below Apple's.
- Luma SSIM is within 0.0015 of Apple's, slightly lower than the earlier native frames (0.9986–0.9992). That is within frame-to-frame encoder variance, but not better.
