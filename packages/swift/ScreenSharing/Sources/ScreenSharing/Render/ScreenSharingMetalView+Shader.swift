import MetalKit

extension ScreenSharingMetalView {
  /// Every pipeline's source: biplanar YCbCr (8- or 10-bit, video or full range) and packed BGRA,
  /// into an 8-bit drawable or, for HDR (851-2380), a 10-bit Display P3 PQ one.
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
    // HDR (851-2380) on a layer that isn't showing HDR yet: PQ to light, SDR white (203 nits,
    // BT.2408) at 1, highlights clipped, back to a gamma the display treats as SDR.
    fragment float4 screenFragmentPQToSDR(ScreenVertex in [[stage_in]],
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant ScreenRange& range [[buffer(0)]]) {
      float3 e = pow(saturate(screenRGB(in, yPlane, uvPlane, range)), float3(1.0/78.84375));
      float3 nits = 10000.0 * pow(max(e - 0.8359375, 0.0) / (18.8515625 - 18.6875 * e), float3(1.0/0.1593017578125));
      // Display P3 to BT.709 primaries, as the SDR path's sRGB content is.
      float3x3 p3To709 = float3x3(float3(1.2249,-0.0420,-0.0197), float3(-0.2247,1.0419,-0.0786), float3(0,0,1.0979));
      float3 linear = saturate(p3To709 * (nits / 203.0));
      return float4(select(1.055*pow(linear, float3(1.0/2.4))-0.055, 12.92*linear, linear <= 0.0031308), 1);
    }
    // SDR in a layer showing HDR (the frame before it switches back): sRGB white at 203 nits, in PQ.
    float4 screenSDRToPQ(float3 srgb) {
      float3 c = saturate(srgb);
      float3 linear = select(pow((c+0.055)/1.055, float3(2.4)), c/12.92, c <= 0.04045);
      float3x3 bt709ToP3 = float3x3(float3(0.8225,0.0332,0.0171), float3(0.1774,0.9669,0.0724), float3(0,0,0.9108));
      float3 y = pow(saturate(bt709ToP3 * linear * (203.0/10000.0)), float3(0.1593017578125));
      return float4(pow((0.8359375 + 18.8515625*y) / (1 + 18.6875*y), float3(78.84375)), 1);
    }
    fragment float4 screenFragmentSDRToPQ(ScreenVertex in [[stage_in]],
      texture2d<float> yPlane [[texture(0)]], texture2d<float> uvPlane [[texture(1)]],
      constant ScreenRange& range [[buffer(0)]]) {
      return screenSDRToPQ(screenRGB(in, yPlane, uvPlane, range));
    }
    fragment float4 screenFragmentBGRAToPQ(ScreenVertex in [[stage_in]], texture2d<float> plane [[texture(0)]]) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      return screenSDRToPQ(plane.sample(sample,in.uv).rgb);
    }
    fragment float4 screenFragmentBGRA(ScreenVertex in [[stage_in]], texture2d<float> plane [[texture(0)]]) {
      constexpr sampler sample(filter::linear, address::clamp_to_edge);
      return float4(plane.sample(sample,in.uv).rgb, 1);
    }
    """
}
