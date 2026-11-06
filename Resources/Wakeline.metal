#include <metal_stdlib>
using namespace metal;

struct FrameU {
    float4x4 vp, ivp;
    float4 eye;     // xyz, time
    float4 lightA, lightB;  // xyz, intensity
    float4 colA, colB;
    float4 shock;   // world x, z, radius, strength
    float4 misc;    // arena w, arena d, pitch, reflection pass
    float4 flash;   // xyz, power
    float4 view;    // pass w, h, impact glow, fade
    float4 shockColor;
};

struct InstU { float4x4 model; float4 color; float4 params; }; // reveal, emissive gain
struct WallU { float4 color; float4 params; };  // head u, dissolve front, height, gain
struct CompU { float4 a; float4 b; };           // exposure, fade, time, aberration | grain, unused, vignette, bloom

constexpr sampler linClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);
constexpr sampler linWrap(filter::linear, mip_filter::linear, s_address::repeat, t_address::clamp_to_edge);

static float3 horizonColor() { return float3(0.030, 0.016, 0.060); }

static float2 equirect(float3 d) {
    return float2(atan2(d.z, d.x) / (2 * M_PI_F) + 0.5, acos(clamp(d.y, -1.0f, 1.0f)) / M_PI_F);
}

static float hash31(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float noise3(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3 - 2 * f);
    return mix(mix(mix(hash31(i), hash31(i + float3(1,0,0)), f.x),
                   mix(hash31(i + float3(0,1,0)), hash31(i + float3(1,1,0)), f.x), f.y),
               mix(mix(hash31(i + float3(0,0,1)), hash31(i + float3(1,0,1)), f.x),
                   mix(hash31(i + float3(0,1,1)), hash31(i + float3(1,1,1)), f.x), f.y), f.z);
}

static float fbm(float3 p) {
    float a = 0.5, s = 0;
    for (int i = 0; i < 6; i++) { s += a * noise3(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return s;
}

// ---------- fullscreen ----------

struct FS { float4 pos [[position]]; float2 uv; };

vertex FS fsVS(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2 - 1;
    FS o; o.pos = float4(p, 0, 1); o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return o;
}

// ---------- sky ----------

// One tilted orbital ring: dashed bands of station lights hanging over the arena.
static float halo(float3 d, float3 axis, float cosA, float seed) {
    float h = dot(d, axis);
    float3 t = normalize(cross(axis, float3(0.31, 0.52, 0.8)));
    float3 b = cross(axis, t);
    float phi = atan2(dot(d, b), dot(d, t));
    float band = 0;
    for (int i = 0; i < 3; i++) {
        float w = 0.0009 + 0.0007 * i;
        float line = smoothstep(w, 0.0, abs(h - cosA - i * 0.0052));
        float dash = smoothstep(0.42, 0.5, fract(phi * (9.0 + i * 14.0) / 6.2831 + seed + i * 0.3));
        band += line * (0.35 + 0.65 * dash);
    }
    float body = smoothstep(0.014, 0.0, abs(h - cosA - 0.005)) * 0.05;
    return band + body;
}

fragment float4 skyBakeFS(FS in [[stage_in]]) {
    float th = (in.uv.x - 0.5) * 2 * M_PI_F, ph = in.uv.y * M_PI_F;
    float3 d = float3(sin(ph) * cos(th), cos(ph), sin(ph) * sin(th));
    float up = max(d.y, 0.0f);

    float3 col = mix(horizonColor(), float3(0.0015, 0.002, 0.007), pow(up, 0.42));
    float n = fbm(d * 2.3 + 4.0);
    float n2 = fbm(d * 5.1 + float3(n * 2.1) + 9.0);
    float cloud = smoothstep(0.42, 0.78, n2) * smoothstep(0.02, 0.32, up);
    col += cloud * (mix(float3(0.10, 0.018, 0.17), float3(0.015, 0.05, 0.13), n)) * 0.42;

    float3 g = floor(d * 330);
    float star = hash31(g);
    if (star > 0.9965) {
        float tw = hash31(g + 3.0);
        col += mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.8, 0.65), tw) * pow((star - 0.9965) / 0.0035, 2.0) * 1.1;
    }

    col += float3(0.5, 0.75, 1.0) * halo(d, normalize(float3(0.34, 0.86, -0.38)), 0.42, 0.13) * 0.85;
    col += float3(0.85, 0.42, 1.0) * halo(d, normalize(float3(-0.55, 0.78, 0.3)), 0.56, 0.61) * 0.45;

    // Horizon bloom that the floor fog dissolves into.
    col += float3(0.30, 0.075, 0.42) * exp(-abs(d.y) * 15.0) * 0.32;
    col += float3(0.04, 0.16, 0.26) * exp(-abs(d.y) * 46.0) * 0.5;
    return float4(col, 1);
}

struct SkyOut { float4 pos [[position]]; float3 ray; };

vertex SkyOut skyVS(uint vid [[vertex_id]], constant FrameU& f [[buffer(0)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2 - 1;
    float4 w = f.ivp * float4(p, 1, 1);
    SkyOut o; o.pos = float4(p, 1, 1); o.ray = w.xyz / w.w - f.eye.xyz;
    return o;
}

fragment float4 skyFS(SkyOut in [[stage_in]], texture2d<float> sky [[texture(0)]]) {
    return float4(sky.sample(linWrap, equirect(normalize(in.ray)), level(0)).rgb, 1);
}

// ---------- floor ----------

struct FloorOut { float4 pos [[position]]; float3 wp; };

vertex FloorOut floorVS(uint vid [[vertex_id]], constant FrameU& f [[buffer(0)]]) {
    const float2 q[6] = {{-1,-1},{1,-1},{1,1},{-1,-1},{1,1},{-1,1}};
    float3 wp = float3(f.misc.x * 0.5 + q[vid].x * 5000, 0, f.misc.y * 0.5 + q[vid].y * 5000);
    FloorOut o; o.pos = f.vp * float4(wp, 1); o.wp = wp;
    return o;
}

static float3 pointLight(float3 wp, float3 N, float3 V, float4 l, float3 col, float shine) {
    float3 L = l.xyz - wp;
    float d2 = dot(L, L);
    L /= sqrt(d2);
    float3 H = normalize(L + V);
    float att = l.w / (d2 + 1.5);
    return col * att * (max(dot(N, L), 0.0f) * 0.26 + pow(max(dot(N, H), 0.0f), shine) * 2.4);
}

fragment float4 floorFS(FloorOut in [[stage_in]], constant FrameU& f [[buffer(0)]],
                        texture2d<float> refl [[texture(0)]], texture2d<float> glow [[texture(1)]]) {
    float3 wp = in.wp;
    float3 Vv = f.eye.xyz - wp;
    float dist = length(Vv);
    float3 V = Vv / dist;
    float2 suv = in.pos.xy / f.view.xy;

    // Soft low-frequency warp keeps the mirror from looking like glass CG.
    float n1 = noise3(float3(wp.xz * 0.07, 1.0));
    float n2 = noise3(float3(wp.xz * 0.31, 4.0));
    float3 N = normalize(float3((n1 - 0.5) * 0.028 + (n2 - 0.5) * 0.012, 1, (n2 - 0.5) * 0.028));
    float rough = 0.6 + 2.2 * n1;

    float NV = max(dot(N, V), 0.0f);
    float F = 0.045 + 0.955 * pow(1 - NV, 5.0f);
    float lod = rough + clamp(dist * 0.006, 0.0f, 1.5f);
    float3 mirror = refl.sample(linClamp, suv + (N.xz) * 0.06, level(lod)).rgb;
    float3 col = float3(0.0022, 0.0028, 0.0048) + mirror * (F * 1.25 + 0.05);

    float2 auv = wp.xz / f.misc.xy;
    bool inside = all(auv > 0.0) && all(auv < 1.0);
    if (inside) {
        // Lattice studs: one small cross at every junction a rider can turn on.
        float p = f.misc.z;
        float2 cell = fract(wp.xz / p) - 0.5;
        float2 a = abs(cell) * p;
        float fw = max(fwidth(wp.x), fwidth(wp.z));
        float w = max(0.035, fw * 0.8);
        float arm = 0.42;
        float mark = max(smoothstep(w + fw, w, a.x) * smoothstep(arm + fw, arm, a.y),
                         smoothstep(w + fw, w, a.y) * smoothstep(arm + fw, arm, a.x));
        col += float3(0.05, 0.08, 0.12) * mark * smoothstep(420.0, 60.0, fw * 900.0);
    }
    // Wall light falls off fast: the floor stays black between lanes however
    // much of the maze has been built.
    float3 near = glow.sample(linClamp, auv, level(0.6)).rgb;
    float3 mid = glow.sample(linClamp, auv, level(1.6)).rgb;
    col += (near * near * 0.34 + mid * 0.15) * (0.7 + 0.3 * n1);

    col += pointLight(wp, N, V, f.lightA, f.colA.rgb, 90.0);
    col += pointLight(wp, N, V, f.lightB, f.colB.rgb, 90.0);
    col += pointLight(wp, N, V, f.flash, f.shockColor.rgb + 0.15, 40.0) * 2.0;

    if (f.shock.w > 0.002) {
        float d = distance(wp.xz, f.shock.xy) - f.shock.z;
        float band = exp(-d * d * 0.09);
        float trail = (d < 0) ? exp(d * 0.11) * 0.2 : 0.0;
        col += f.shockColor.rgb * (band + trail) * f.shock.w * 0.9;
    }
    float fog = 1 - exp(-pow(max(dist - 400.0, 0.0f) * 0.00135, 2.0f));
    return float4(mix(col, horizonColor() * 2.2, fog), 1);
}

// ---------- meshes ----------

struct MV { packed_float3 p; packed_float3 n; float m; };
struct MeshOut {
    float4 pos [[position]];
    float3 wp, n, tint;
    float mat [[flat]];
    float reveal [[flat]];
    float gain [[flat]];
};

vertex MeshOut meshVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device MV* v [[buffer(0)]], constant FrameU& f [[buffer(1)]],
                      constant InstU* inst [[buffer(2)]]) {
    InstU I = inst[iid];
    float4 w = I.model * float4(float3(v[vid].p), 1);
    MeshOut o;
    o.pos = f.vp * w;
    o.wp = w.xyz;
    o.n = (I.model * float4(float3(v[vid].n), 0)).xyz;
    o.tint = I.color.rgb; o.mat = v[vid].m; o.reveal = I.params.x; o.gain = I.params.y;
    return o;
}

fragment float4 meshFS(MeshOut in [[stage_in]], constant FrameU& f [[buffer(0)]],
                       texture2d<float> sky [[texture(0)]]) {
    if (in.wp.y > in.reveal) discard_fragment();
    float3 N = normalize(in.n), V = normalize(f.eye.xyz - in.wp);
    int m = int(in.mat + 0.5);
    if (m == 1) {
        float hot = 1 + 0.2 * sin(f.eye.w * 9 + in.wp.y * 3);
        return float4(mix(in.tint, float3(1), 0.14) * in.gain * hot, 1);
    }
    float3 albedo = m == 2 ? float3(0.62, 0.66, 0.72) : (m == 3 ? float3(0.012) : float3(0.016, 0.018, 0.026));
    float metal = m == 3 ? 0.0 : (m == 2 ? 1.0 : 0.85);
    float rough = m == 2 ? 0.16 : (m == 3 ? 0.75 : 0.26);
    float3 F0 = mix(float3(0.04), albedo, metal);
    float NV = max(dot(N, V), 0.0f);
    float3 Fr = F0 + (1 - F0) * pow(1 - NV, 5.0f);
    float3 R = reflect(-V, N);
    float3 env = sky.sample(linWrap, equirect(R), level(rough * 7)).rgb;
    float3 col = env * Fr * 3.0;
    col += in.tint * pow(1 - NV, 3.0f) * 0.55;
    // The floor is the brightest thing bikes "see": fake its bounce from below.
    col += in.tint * saturate(-N.y) * 0.1 * Fr;
    float shine = 2.0 / (rough * rough) ;
    col += pointLight(in.wp, N, V, f.lightA, f.colA.rgb, shine) * mix(float3(1), albedo * 4, metal) * 1.6;
    col += pointLight(in.wp, N, V, f.lightB, f.colB.rgb, shine) * mix(float3(1), albedo * 4, metal) * 1.6;
    col += pointLight(in.wp, N, V, f.flash, float3(1, 0.9, 0.8), shine) * 4.0;
    float edge = smoothstep(in.reveal - 0.18, in.reveal, in.wp.y);
    col += in.tint * edge * 6.0;
    return float4(col, 1);
}

// ---------- walls ----------

struct WallV { float4 a; float4 b; };  // xyz + along-trail u | height 0..1, top flag
struct WallOut { float4 pos [[position]]; float3 wp; float u, h, top, across; };

vertex WallOut wallVS(uint vid [[vertex_id]], const device WallV* v [[buffer(0)]], constant FrameU& f [[buffer(1)]]) {
    WallOut o;
    o.pos = f.vp * float4(v[vid].a.xyz, 1);
    o.wp = v[vid].a.xyz; o.u = v[vid].a.w; o.h = v[vid].b.x; o.top = v[vid].b.y; o.across = v[vid].b.z;
    return o;
}

fragment float4 wallFS(WallOut in [[stage_in]], constant FrameU& f [[buffer(0)]], constant WallU& w [[buffer(1)]]) {
    float t = f.eye.w;
    float toFront = in.u - w.params.y;
    if (toFront > 0) discard_fragment();
    float age = w.params.x - in.u;
    float risen = smoothstep(-0.4, 2.6, age);
    if (in.h > risen + 0.02) discard_fragment();

    float3 c = w.color.rgb;
    float hot = 1.0 + 3.4 * exp(-age * 0.05);                      // fresh wall burns brighter
    float eat = exp(toFront * 0.16);                                // white-hot dissolve lip
    float d = distance(in.wp.xz, f.shock.xy) - f.shock.z;
    float shock = f.shock.w * exp(-d * d * 0.03) * 2.2;

    if (in.top > 0.5) {
        float core = exp(-in.across * in.across * 7.0);
        float3 col = (c * (2.1 + 2.4 * core) + float3(0.55) * core * core) * hot * w.params.w;
        col += (c + 0.6) * shock + float3(1) * eat * 7.0;
        return float4(col, 1);
    }
    // Sides: a smoked energy pane, brightest at the rim, with current racing down it.
    float flow = 0.5 + 0.5 * sin(in.u * 0.55 - t * 11.0);
    flow = pow(flow, 10.0);
    float fine = 0.5 + 0.5 * sin(in.h * 34.0);
    float rim = pow(in.h, 5.0) * 1.9 + exp(-in.h * 16.0) * 0.8;
    float body = 0.14 + 0.3 * in.h * in.h + flow * 0.5 * (0.4 + 0.6 * in.h) + fine * 0.018;
    float3 V = normalize(f.eye.xyz - in.wp);
    float graze = pow(1 - abs(V.y), 2.0) * 0.4 + 0.6;
    float3 col = c * (rim * 2.8 + body) * hot * graze * w.params.w;
    col += (c + 0.6) * shock * 0.6 + float3(1) * eat * 4.0;
    float alpha = clamp(0.32 + 0.45 * in.h + flow * 0.2, 0.0, 1.0);
    return float4(col, alpha);
}

// ---------- particles ----------

struct PV { float4 pos; float4 vel; float4 color; };
struct POut { float4 pos [[position]]; float2 uv; float3 c; };

vertex POut partVS(uint vid [[vertex_id]], uint iid [[instance_id]],
                   const device PV* ps [[buffer(0)]], constant FrameU& f [[buffer(1)]]) {
    const float2 q[6] = {{-1,-1},{1,-1},{1,1},{-1,-1},{1,1},{-1,1}};
    PV p = ps[iid];
    float2 c = q[vid];
    float3 toCam = normalize(f.eye.xyz - p.pos.xyz);
    float speed = length(p.vel.xyz);
    float3 axis = speed > 0.05 ? p.vel.xyz / speed : float3(0, 1, 0);
    float3 side = normalize(cross(axis, toCam) + 1e-4);
    float3 along = cross(side, toCam);
    if (p.vel.w > 0) along = axis;
    float len = p.pos.w + p.vel.w * speed;
    float3 w = p.pos.xyz + side * c.x * p.pos.w + along * c.y * len;
    POut o; o.pos = f.vp * float4(w, 1); o.uv = c; o.c = p.color.rgb;
    return o;
}

fragment float4 partFS(POut in [[stage_in]]) {
    float r = 1 - dot(in.uv, in.uv);
    if (r <= 0) discard_fragment();
    return float4(in.c * r * r, 0);
}

// ---------- post ----------

// Dual-filter bloom: 13-tap down, tent up.
fragment float4 bloomDownFS(FS in [[stage_in]], texture2d<float> t [[texture(0)]], constant float2& px [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 a = t.sample(linClamp, uv + px * float2(-2, -2), level(0)).rgb, b = t.sample(linClamp, uv + px * float2(0, -2), level(0)).rgb;
    float3 c = t.sample(linClamp, uv + px * float2(2, -2), level(0)).rgb, d = t.sample(linClamp, uv + px * float2(-2, 0), level(0)).rgb;
    float3 e = t.sample(linClamp, uv, level(0)).rgb, g = t.sample(linClamp, uv + px * float2(2, 0), level(0)).rgb;
    float3 h = t.sample(linClamp, uv + px * float2(-2, 2), level(0)).rgb, i = t.sample(linClamp, uv + px * float2(0, 2), level(0)).rgb;
    float3 j = t.sample(linClamp, uv + px * float2(2, 2), level(0)).rgb, k = t.sample(linClamp, uv + px * float2(-1, -1), level(0)).rgb;
    float3 l = t.sample(linClamp, uv + px * float2(1, -1), level(0)).rgb, m = t.sample(linClamp, uv + px * float2(-1, 1), level(0)).rgb;
    float3 n = t.sample(linClamp, uv + px * float2(1, 1), level(0)).rgb;
    float3 o = e * 0.125 + (a + c + h + j) * 0.03125 + (b + d + g + i) * 0.0625 + (k + l + m + n) * 0.125;
    return float4(min(o, float3(40.0)), 1);
}

fragment float4 bloomUpFS(FS in [[stage_in]], texture2d<float> t [[texture(0)]], constant float2& px [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 s = t.sample(linClamp, uv, level(0)).rgb * 4;
    s += (t.sample(linClamp, uv + float2(px.x, 0), level(0)).rgb + t.sample(linClamp, uv - float2(px.x, 0), level(0)).rgb
        + t.sample(linClamp, uv + float2(0, px.y), level(0)).rgb + t.sample(linClamp, uv - float2(0, px.y), level(0)).rgb) * 2;
    s += t.sample(linClamp, uv + px, level(0)).rgb + t.sample(linClamp, uv - px, level(0)).rgb
       + t.sample(linClamp, uv + float2(px.x, -px.y), level(0)).rgb + t.sample(linClamp, uv + float2(-px.x, px.y), level(0)).rgb;
    return float4(s / 16 * 0.85, 1);
}

static float3 aces(float3 x) {
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 compositeFS(FS in [[stage_in]], texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]],
                            constant CompU& u [[buffer(0)]]) {
    float2 uv = in.uv, c = uv - 0.5;
    float r2 = dot(c, c);
    float2 ab = c * r2 * u.a.w;
    float3 col = float3(hdr.sample(linClamp, uv + ab, level(0)).r, hdr.sample(linClamp, uv, level(0)).g, hdr.sample(linClamp, uv - ab, level(0)).b);
    col += bloom.sample(linClamp, uv, level(0)).rgb * u.b.w;
    col *= u.a.x * (1 - r2 * u.b.z);
    col = aces(col);
    col = pow(col, float3(1 / 2.2));
    float n = fract(sin(dot(in.pos.xy + u.a.z * 91.7, float2(12.9898, 78.233))) * 43758.5453);
    col += (n - 0.5) * u.b.x;
    return float4(col * u.a.y, 1);
}
