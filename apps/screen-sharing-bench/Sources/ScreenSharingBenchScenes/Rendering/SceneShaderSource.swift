enum SceneShaderSource {
  static let vertexFunction = "sceneVertex"

  static let text = """
    #include <metal_stdlib>
    using namespace metal;

    struct SceneUniforms {
      int version;
      int count;
      int2 offset;
      int2 size;
      int2 extent;
      uint seed;
      int spare;
    };

    struct Raster {
      float4 position [[position]];
    };

    constant float4 white = float4(1.0);
    constant float4 black = float4(0.0, 0.0, 0.0, 1.0);

    vertex Raster sceneVertex(uint vid [[vertex_id]]) {
      float2 corner = float2((vid << 1) & 2, vid & 2);
      Raster out;
      out.position = float4(corner * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
      return out;
    }

    static int2 pixelOf(Raster in) {
      return int2(in.position.xy);
    }

    static float4 gray(float value) {
      return float4(value, value, value, 1.0);
    }

    static bool inside(int2 p, int2 origin, int2 size) {
      return all(p >= origin) && all(p < origin + size);
    }

    static float4 withBarcode(int2 p, float4 color, texture2d<float, access::read> barcode) {
      int2 size = int2(barcode.get_width(), barcode.get_height());
      return inside(p, int2(0), size) ? barcode.read(uint2(p)) : color;
    }

    static uint hashed(uint3 v) {
      uint h = v.x * 0x8da6b343u ^ v.y * 0xd8163841u ^ v.z * 0xcb1ab31fu;
      h ^= h >> 16;
      h *= 0x7feb352du;
      h ^= h >> 15;
      return h;
    }

    fragment float4 idleCursor(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]], texture2d<float, access::read> page [[texture(1)]]
    ) {
      int2 p = pixelOf(in);
      float4 color = gray(page.read(uint2(p)).r);
      if (u.count != 0 && inside(p, u.offset, u.size)) color = black;
      return withBarcode(p, color, barcode);
    }

    fragment float4 typing(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]], texture2d<float, access::read> page [[texture(1)]],
      texture2d<uint, access::read> cells [[texture(2)]]
    ) {
      int2 p = pixelOf(in);
      float4 color = white;
      int2 grid = int2(cells.get_width(), cells.get_height());
      if (inside(p, u.offset, u.size * grid)) {
        uint order = cells.read(uint2((p - u.offset) / u.size)).r;
        if (order < uint(u.count)) color = gray(page.read(uint2(p)).r);
      }
      return withBarcode(p, color, barcode);
    }

    fragment float4 scroll(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]], texture2d<float, access::read> document [[texture(1)]]
    ) {
      int2 p = pixelOf(in);
      uint y = (uint(p.y) + uint(u.offset.y)) % document.get_height();
      return withBarcode(p, gray(document.read(uint2(p.x, y)).r), barcode);
    }

    static float4 desktop(int2 p, int2 extent) {
      float2 uv = float2(p) / float2(extent);
      float3 base = mix(float3(0.16, 0.30, 0.52), float3(0.55, 0.36, 0.62), uv.x * 0.6 + uv.y * 0.4);
      bool line = (p.x % 96) < 2 || (p.y % 96) < 2;
      return float4(line ? base * 0.85 : base, 1.0);
    }

    fragment float4 windowDrag(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]], texture2d<float, access::read> window [[texture(1)]]
    ) {
      int2 p = pixelOf(in);
      int2 size = int2(window.get_width(), window.get_height());
      float4 color = inside(p, u.offset, size) ? window.read(uint2(p - u.offset)) : desktop(p, u.extent);
      return withBarcode(p, color, barcode);
    }

    fragment float4 video(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]], texture2d<float, access::read> noise [[texture(1)]]
    ) {
      int2 p = pixelOf(in);
      uint2 grain = (uint2(p) + uint2(u.offset)) % uint2(noise.get_width(), noise.get_height());
      float t = float(u.version) / 60.0;
      float2 uv = float2(p) / float2(u.extent);
      float2 a = float2(0.5 + 0.35 * cos(t * 0.9), 0.5 + 0.35 * sin(t * 1.3));
      float2 b = float2(0.5 + 0.40 * sin(t * 0.7 + 1.0), 0.5 + 0.30 * cos(t * 1.1 + 2.0));
      float3 color = float3(0.08)
        + float3(0.90, 0.35, 0.20) * (1.0 - saturate(distance(uv, a) * 1.6))
        + float3(0.15, 0.45, 0.95) * (1.0 - saturate(distance(uv, b) * 1.4));
      color += (noise.read(grain).r - 0.5) * 0.35;
      return withBarcode(p, float4(saturate(color), 1.0), barcode);
    }

    static float4 photo(int2 p, int2 extent, uint seed) {
      float2 uv = float2(p) / float2(extent);
      float phase = float(seed % 997u) * 0.013;
      float horizon = 0.55 + 0.06 * sin(uv.x * 7.0 + phase) + 0.03 * sin(uv.x * 23.0 + phase * 2.0);
      float3 sky = mix(float3(0.98, 0.78, 0.55), float3(0.35, 0.58, 0.90), saturate(1.0 - uv.y / horizon));
      float sun = 1.0 - smoothstep(0.05, 0.06, distance(uv * float2(1.0, 0.6), float2(0.72, 0.18)));
      sky = mix(sky, float3(1.0, 0.95, 0.80), sun);
      float ridge = 0.72 + 0.05 * sin(uv.x * 13.0 + phase * 3.0);
      float3 land = uv.y < ridge ? float3(0.22, 0.45, 0.20) : float3(0.45, 0.35, 0.22);
      land *= 0.75 + 0.25 * sin(uv.x * 140.0 + uv.y * 90.0 + phase);
      float grain = float(hashed(uint3(uint2(p), seed)) & 0xffu) / 255.0 - 0.5;
      float3 color = uv.y < horizon ? sky : land;
      return float4(saturate(color + grain * 0.08), 1.0);
    }

    static float4 fiducial(int2 local, int2 size) {
      int ring = min(min(local.x, local.y), min(size.x - 1 - local.x, size.y - 1 - local.y));
      int unit = size.x / 16;
      return (ring < 3 * unit || ring >= 5 * unit) ? black : white;
    }

    static float4 withFiducials(int2 p, float4 color, constant SceneUniforms &u) {
      int2 far = u.extent - u.size - int2(u.offset.x);
      int2 origins[4] = { u.offset, int2(far.x, u.offset.y), int2(u.offset.x, far.y), far };
      for (int i = 0; i < 4; i++) {
        if (inside(p, origins[i], u.size)) return fiducial(p - origins[i], u.size);
      }
      return color;
    }

    fragment float4 testCards(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]], texture2d<float, access::read> card [[texture(1)]]
    ) {
      int2 p = pixelOf(in);
      float4 color = u.count != 0 ? photo(p, u.extent, u.seed) : card.read(uint2(p));
      return withBarcode(p, withFiducials(p, color, u), barcode);
    }

    fragment float4 input(
      Raster in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
      texture2d<float, access::read> barcode [[texture(0)]]
    ) {
      int2 p = pixelOf(in);
      float4 color = gray(0.5);
      if (inside(p, u.offset, u.size)) color = (u.version % 2 == 0) ? black : white;
      return withBarcode(p, color, barcode);
    }
    """
}
