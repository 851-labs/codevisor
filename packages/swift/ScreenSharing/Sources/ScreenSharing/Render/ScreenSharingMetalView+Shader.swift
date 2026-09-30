import MetalKit

extension ScreenSharingMetalView {
  /// Every pipeline's source: biplanar YCbCr (8- or 10-bit, video or full range) and packed BGRA,
  /// into an 8-bit drawable or, for HDR (851-2380), a half-float extended-linear Display P3 one.
  static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct ScreenVertex { float4 position [[position]]; float2 uv; };
    vertex ScreenVertex screenVertex(uint id [[vertex_id]]) {
      float2 positions[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
      float2 p = positions[id];
      return {float4(p,0,1), float2((p.x+1)*0.5, (1-p.y)*0.5)};
    }
    // Offsets and scales that take normalized plane samples to Y 0...1 and CbCr -0.5...0.5.
    struct ScreenRange { float yOffset; float yScale; float cOffset; float cScale; };
    float3 screenRGB(ScreenVertex in, texture2d<float> yPlane, texture2d<float> uvPlane, constant ScreenRange& range) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      float y = (yPlane.sample(sample,in.uv).r - range.yOffset) * range.yScale;
      float2 uv = (uvPlane.sample(sample,in.uv).rg - float2(range.cOffset)) * range.cScale;
      // BT.709 matrix: the host's 8-bit sRGB and its HDR capture (Display P3 PQ) both use it.
      return float3(y+1.5748*uv.y, y-0.187324*uv.x-0.468124*uv.y, y+1.8556*uv.x);
    }
    fragment float4 screenFragment(ScreenVertex in [[stage_in]],
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant ScreenRange& range [[buffer(0)]]) {
      return float4(screenRGB(in, yPlane, uvPlane, range), 1);
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
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant ScreenRange& range [[buffer(0)]]) {
      return float4(screenPQToLinear(screenRGB(in, yPlane, uvPlane, range)), 1);
    }
    // HDR on a layer that isn't showing HDR yet: highlights clipped, BT.709 primaries, sRGB gamma.
    fragment float4 screenFragmentPQToSDR(ScreenVertex in [[stage_in]],
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant ScreenRange& range [[buffer(0)]]) {
      float3x3 p3To709 = float3x3(float3(1.2249,-0.0420,-0.0197), float3(-0.2247,1.0419,-0.0786), float3(0,0,1.0979));
      float3 linear = saturate(p3To709 * screenPQToLinear(screenRGB(in, yPlane, uvPlane, range)));
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
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant ScreenRange& range [[buffer(0)]]) {
      return screenSDRToLinear(screenRGB(in, yPlane, uvPlane, range));
    }
    fragment float4 screenFragmentBGRAToLinear(ScreenVertex in [[stage_in]], texture2d<float> plane [[texture(0)]]) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      return screenSDRToLinear(plane.sample(sample,in.uv).rgb);
    }
    fragment float4 screenFragmentBGRA(ScreenVertex in [[stage_in]], texture2d<float> plane [[texture(0)]]) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      return float4(plane.sample(sample,in.uv).rgb, 1);
    }
    """
}
