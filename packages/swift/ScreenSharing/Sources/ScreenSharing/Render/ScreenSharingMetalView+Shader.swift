import MetalKit

extension ScreenSharingMetalView {
  package nonisolated static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct ScreenVertex { float4 position [[position]]; float2 uv; };
    vertex ScreenVertex screenVertex(uint id [[vertex_id]]) {
      float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
      float2 p = positions[id];
      return {float4(p,0,1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
    }
    struct ScreenTile {
      float tiled; float pictureRows; float pictureColumns; float pixelColumns; float start; float rows;
      float aboveRows; float hasAbove; float hasBelow;
    };
    float4 tileSample(texture2d<float> plane, texture2d<float> above, texture2d<float> below, float2 uv,
      constant ScreenTile& t) {
      constexpr sampler whole(filter::linear, address::clamp_to_edge);
      if (t.tiled < 0.5) return plane.sample(whole, uv);
      constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
      float k = float(plane.get_width()) / t.pixelColumns;
      float x = min(uv.x * (t.pictureColumns * k), t.pictureColumns * k - 0.5);
      float y = uv.y * (t.pictureRows * k) - t.start * k;
      float last = t.rows * k;
      if (t.hasAbove > 0.5 && y < 0.5) {
        float edge = t.aboveRows * k;
        if (y <= -0.5) return above.sample(s, float2(x, edge + y));
        return mix(above.sample(s, float2(x, edge - 0.5)), plane.sample(s, float2(x, 0.5)), y + 0.5);
      }
      if (t.hasBelow > 0.5 && y > last - 0.5) {
        if (y >= last + 0.5) return below.sample(s, float2(x, y - last));
        return mix(plane.sample(s, float2(x, last - 0.5)), below.sample(s, float2(x, 0.5)), y - (last - 0.5));
      }
      return plane.sample(s, float2(x, min(y, last - 0.5)));
    }
    #define SCREEN_PLANES texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]], \
      texture2d<float> yAbove [[texture(2)]], texture2d<float> uvAbove [[texture(3)]], \
      texture2d<float> yBelow [[texture(4)]], texture2d<float> uvBelow [[texture(5)]], \
      constant ScreenRange& range [[buffer(0)]], constant ScreenTile& tile [[buffer(1)]]
    #define SCREEN_RGB screenRGB(in, yPlane, uvPlane, yAbove, uvAbove, yBelow, uvBelow, range, tile)
    #define SCREEN_BGRA texture2d<float> plane [[texture(0)]], texture2d<float> above [[texture(2)]], \
      texture2d<float> below [[texture(4)]], constant ScreenTile& tile [[buffer(1)]]
    // Offsets and scales that take normalized plane samples to Y 0...1 and CbCr -0.5...0.5.
    struct ScreenRange { float yOffset; float yScale; float cOffset; float cScale; };
    float3 screenRGB(ScreenVertex in, texture2d<float> yPlane, texture2d<float> uvPlane, texture2d<float> yAbove,
      texture2d<float> uvAbove, texture2d<float> yBelow, texture2d<float> uvBelow, constant ScreenRange& range,
      constant ScreenTile& tile) {
      float y = (tileSample(yPlane, yAbove, yBelow, in.uv, tile).r - range.yOffset) * range.yScale;
      float2 uv = (tileSample(uvPlane, uvAbove, uvBelow, in.uv, tile).rg - float2(range.cOffset)) * range.cScale;
      // BT.709 matrix: the host's 8-bit sRGB and its HDR capture (Display P3 PQ) both use it.
      return float3(y+1.5748*uv.y, y-0.187324*uv.x-0.468124*uv.y, y+1.8556*uv.x);
    }
    fragment float4 screenFragment(ScreenVertex in [[stage_in]],
      SCREEN_PLANES) {
      return float4(SCREEN_RGB, 1);
    }
    // HDR (851-2380): PQ to light, in Display P3, with the host's SDR white at 1.0. ScreenCaptureKit's
    // HDR capture of a display puts it at 100 nits (tuftlord, 2026-09-30: code 510 of 1023 video
    // range, at every brightness; a single window's capture uses 203 instead). On an
    // extended-linear layer macOS shows 1.0 as this Mac's own white and anything above as highlight,
    // up to the display's headroom; no tone curve moves the host's windows.
    float3 screenPQToLinear(float3 pq) {
      float3 e = pow(saturate(pq), float3(1.0/78.84375));
      float3 nits = 10000.0 * pow(max(e - 0.8359375, 0.0) / (18.8515625 - 18.6875 * e), float3(1.0/0.1593017578125));
      return nits / 100.0;
    }
    fragment float4 screenFragmentPQToLinear(ScreenVertex in [[stage_in]],
      SCREEN_PLANES) {
      return float4(screenPQToLinear(SCREEN_RGB), 1);
    }
    // HDR on a layer that isn't showing HDR yet: highlights clipped, BT.709 primaries, sRGB gamma.
    fragment float4 screenFragmentPQToSDR(ScreenVertex in [[stage_in]],
      SCREEN_PLANES) {
      float3x3 p3To709 = float3x3(float3(1.2249,-0.0420,-0.0197), float3(-0.2247,1.0419,-0.0786), float3(0,0,1.0979));
      float3 linear = saturate(p3To709 * screenPQToLinear(SCREEN_RGB));
      return float4(select(1.055*pow(linear, float3(1.0/2.4))-0.055, 12.92*linear, linear <= 0.0031308), 1);
    }
    // SDR on a layer showing HDR (the frame before it switches back): sRGB to linear Display P3.
    float4 screenSDRToLinear(float3 srgb) {
      float3 c = saturate(srgb);
      float3 linear = select(pow((c+0.055)/1.055, float3(2.4)), c/12.92, c <= 0.04045);
      float3x3 bt709ToP3 = float3x3(float3(0.8225,0.0332,0.0171), float3(0.1774,0.9669,0.0724), float3(0,0,0.9108));
      return float4(bt709ToP3 * linear, 1);
    }
    fragment float4 screenFragmentSDRToLinear(ScreenVertex in [[stage_in]],
      SCREEN_PLANES) {
      return screenSDRToLinear(SCREEN_RGB);
    }
    fragment float4 screenFragmentBGRAToLinear(ScreenVertex in [[stage_in]], SCREEN_BGRA) {
      return screenSDRToLinear(tileSample(plane, above, below, in.uv, tile).rgb);
    }
    fragment float4 screenFragmentBGRA(ScreenVertex in [[stage_in]], SCREEN_BGRA) {
      return float4(tileSample(plane, above, below, in.uv, tile).rgb, 1);
    }
    """
}
