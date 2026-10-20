// BlackHoleDelete — shaders. Three passes, all in screen points (origin top-left):
//  • backdrop — wallpaper snapshot with lens, twist, deep shade and bloom (under the chat list);
//  • mesh     — message snapshots on a grid, pulled into the hole (above the chat list);
//  • overlay  — black island shape and the light ring from the disk texture (above the nav bar).

#include <metal_stdlib>
using namespace metal;

namespace blackhole {

float stadiumDistance(float2 p, float2 center, float2 halfSize) {
    float r = min(halfSize.x, halfSize.y);
    float2 q = fabs(p - center) - (halfSize - r);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float hash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }

constant float2 quad[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

}

// MARK: - Backdrop

struct BackdropUniforms {
    float4 view;    // width, height (pt), scale, time
    float4 hole;    // center x, y, radius (pt), presence
    float4 shape;   // half size of the shape (pt), lens, swirl
    float4 space;   // darkness, size (in radii), spin angle, glow
};

struct ScreenOut {
    float4 position [[position]];
    float2 point;
};

vertex ScreenOut blackHoleScreenVertex(uint vid [[vertex_id]], constant float4 &view [[buffer(0)]]) {
    float2 c = blackhole::quad[vid];
    ScreenOut out;
    out.position = float4(c.x * 2.0 - 1.0, 1.0 - c.y * 2.0, 0.0, 1.0);
    out.point = c * view.xy;
    return out;
}

/// Opaque replacement of the wallpaper while the hole is open: identical to the snapshot when
/// presence = 0, so the host can swap it in and out without a visible change.
fragment half4 blackHoleBackdropFragment(ScreenOut in [[stage_in]], constant BackdropUniforms &u [[buffer(0)]],
                                         texture2d<half> wallpaper [[texture(0)]]) {
    // Mirrored repeat: the twist may sample outside the snapshot — no smeared edge pixels.
    constexpr sampler smp(filter::linear, address::mirrored_repeat);
    float2 size = max(u.view.xy, float2(1.0));
    float2 position = in.point;
    float2 center = u.hole.xy;
    float r = max(u.hole.z, 1.0);
    float presence = u.hole.w;
    float lens = u.shape.z, swirl = u.shape.w;
    float2 d = position - center;
    float dist = max(length(d), 0.001);
    float2 n = d / dist;
    float pull = lens * r * 0.7 * exp(-max(dist - r, 0.0) / (r * 1.3));
    // Twist: the closer to the hole, the more the pattern turns (clockwise on screen);
    // the spin angle grows while the hole is open — the wallpaper keeps swirling.
    float e1 = max(dist - r, 0.0) / (r * 1.4);
    float e2 = max(dist - r, 0.0) / (r * 1.0);
    float twist = -(swirl * exp(-e1 * e1) + u.space.z * exp(-e2 * e2));
    float2 swirled = float2(n.x * cos(twist) - n.y * sin(twist), n.x * sin(twist) + n.y * cos(twist));
    float2 source = center + swirled * max(dist - pull, r * 0.2);
    float3 c = float3(wallpaper.sample(smp, source / size).rgb);

    // Deep shade: gaussian falloff, "multiply on itself" — darker and more saturated, not grey.
    float x = max(dist / r - 0.9, 0.0) / max(u.space.y, 0.1);
    float a = clamp(u.space.x * exp(-x * x), 0.0, 1.0);
    float3 shaded = pow(max(c, float3(0.0)), float3(1.0 + 3.2 * a)) * (1.0 - 0.3 * a);

    // Bloom around the ring — light added to the wallpaper, fading smoothly towards the edge.
    float glow = u.space.w;
    if (glow > 0.001 && presence > 0.001) {
        float2 hs = max(u.shape.xy, float2(1.0));
        float rs0 = min(hs.x, hs.y);
        float sd = blackhole::stadiumDistance(position, center, hs);
        float rr = (sd + rs0) / rs0;
        float e0 = max(rr - 1.0, 0.0);
        if (e0 < 3.4 && rr >= 1.0) {
            float3 bloom = (float3(1.0, 0.9, 0.55) * exp(-e0 / 0.34) * 0.7 + float3(1.0, 0.85, 0.5) * exp(-e0 / 1.35) * 0.45)
                         * glow * smoothstep(0.0, 0.45, presence) * smoothstep(1.0, 1.06, rr)
                         * (1.0 - smoothstep(2.4, 3.4, e0));
            shaded = min(shaded + bloom, float3(1.0));
        }
    }
    shaded += (blackhole::hash(position) - 0.5) / 255.0;   // dither against banding
    return half4(half3(shaded), 1.0h);
}

// MARK: - Overlay (black shape + light ring)

struct OverlayUniforms {
    float4 view;    // width, height (pt), scale, time
    float4 hole;    // center x, y, radius (pt), visibility 0…1
    float4 shape;   // half size (pt), inner boost, inner width
    float4 img;     // disk texture: shadow center x, y, shadow radius (px), spin speed
    float4 look;    // texture w, h (px), brightness, mip level
    float4 ring;    // arc angle (rad), spin (rad/s), squeeze, gamma
};

struct OverlayOut {
    float4 position [[position]];
    float2 point;
};

/// Only the bounding box of the hole + ring is rasterized.
vertex OverlayOut blackHoleOverlayVertex(uint vid [[vertex_id]], constant OverlayUniforms &u [[buffer(0)]]) {
    float r = max(u.hole.z, 1.0);
    float2 extent = u.shape.xy + r * (0.425 / max(u.ring.z, 0.1) + 0.05);
    float2 point = u.hole.xy - extent + blackhole::quad[vid] * extent * 2.0;
    OverlayOut out;
    out.position = float4(point.x / u.view.x * 2.0 - 1.0, 1.0 - point.y / u.view.y * 2.0, 0.0, 1.0);
    out.point = point;
    return out;
}

static float lumOf(half3 c) { return float(max(c.r, max(c.g, c.b))); }

fragment half4 blackHoleOverlayFragment(OverlayOut in [[stage_in]], constant OverlayUniforms &u [[buffer(0)]],
                                        texture2d<half> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    float2 hs = max(u.shape.xy, float2(1.0));
    float sd = blackhole::stadiumDistance(in.point, u.hole.xy, hs);
    // Black island shape — always (it covers the system island at rest).
    float body = 1.0 - smoothstep(-0.6, 0.6, sd);
    float vis = u.hole.w;
    if (vis < 0.002) { return half4(0.0h, 0.0h, 0.0h, half(body)); }

    float r = max(u.hole.z, 1.0);
    float2 q = (in.point - u.hole.xy) / r;
    float qs = 1.0 + sd / r;                                // distance to the shape, in hole radii
    float photon = exp(-pow((qs - 1.012) / 0.0065, 2.0));
    // Ring profile — the clean upper arc of the texture, mapped around the whole circle:
    // θ = θmax·tri(φ + spin), continuous, no stretching at the sides. Clockwise; fibers near the
    // horizon spin faster (like orbits) — they move along their own trajectories.
    float phi = atan2(q.x, q.y);
    float near = exp(-max(qs - 1.0, 0.0) / max(u.shape.w, 0.01));
    float spin = u.view.w * u.ring.y * u.img.w * (0.6 + u.shape.z * near);
    float theta = u.ring.x * (2.0 / M_PI_F) * asin(sin(phi + spin));
    // Nonlinear radial remap o = W·(x/Ws)^γ: the brightest band of the texture is pulled to the
    // horizon, the fibrous part stretches over the rest. Light in the texture: 1.075 … 1.5 radii.
    float xr = max(qs - 1.0, 0.0);
    float ringW = 0.425;
    float ringWs = ringW / max(u.ring.z, 0.1);
    float rs = 1.075 + ringW * pow(xr / ringWs, u.ring.w);
    float2 pr = (u.img.xy + float2(sin(theta), -cos(theta)) * rs * u.img.z) / u.look.xy;
    half3 c = tex.sample(smp, pr, level(u.look.w)).rgb;
    c += tex.sample(smp, pr, level(3.5)).rgb * 0.22h;
    half l = max(c.r, max(c.g, c.b));
    c = mix(c, l * half3(1.0h, 0.95h, 0.86h), 0.6h) * half(u.look.z);
    // Light over the chat: almost additive, dim fibers don't darken content.
    half a = clamp(half(lumOf(c) * 0.9), 0.0h, 1.0h);
    half keep = half(smoothstep(0.995, 1.004, qs));         // no light inside the shadow
    c *= keep;
    a *= keep;
    c += half3(half(photon * 0.95));
    a = max(a, half(photon));
    c = min(c, half3(1.0h)) * half(vis);
    a *= half(vis);
    // Black body on top of the light (premultiplied).
    return half4(c * half(1.0 - body), a * half(1.0 - body) + half(body));
}

// MARK: - Mesh (messages pulled into the hole)
//
// Each message is a texture on a grid; vertices are moved by a flow towards the hole, so only a
// few hundred vertices are computed, not screen pixels. The flow goes along rays to the hole
// center; its speed depends on the "height" above the hole D = ρ·k(φ) − r, k = cos(φ)^shape.
// v(D) = speed · (1 + strength · e^(−D/reach)): far away messages fly undistorted, near the horizon
// the flow accelerates sharply — the message stretches into a "spaghetti" and narrows along rays.
// Near the halo it fades and blurs (coarser mip level).

struct MeshUniforms {
    float4 view;    // width, height (pt), scale
    float4 hole;    // center x, y, horizon radius, time since swallow start
    float4 flow;    // speed (pt/s), strength, reach (pt), ramp (s)
    float4 extra;   // sink (pt), swirl, shape, acceleration (1/s)
    float4 fade;    // fade start, fade end (radii), blur (pt), pull while opening
    float4 frame;   // message frame x, y, width, height (pt)
    float4 grid;    // columns, rows
};

struct MeshOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
    float lod;
    float heat;
};

namespace blackhole {

float travelTime(float x, float4 flow) {
    float reach = max(flow.z, 1.0);
    return (x + reach * log(1.0 + flow.y * exp(-x / reach))) / max(flow.x, 1.0);
}

float easedTime(float tau, float ramp, float accel) {
    float eased = ramp > 0.001 ? tau - ramp * (1.0 - exp(-tau / ramp)) : tau;
    return accel > 0.001 ? (exp(accel * eased) - 1.0) / accel : eased;
}

float shapeFactor(float rho, float cosPhi, float horizon, float shape) {
    float w = smoothstep(horizon * 1.0, horizon * 4.0, rho);
    return pow(cosPhi, shape * w);
}

constant uint2 corners[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

}

vertex MeshOut blackHoleMeshVertex(uint vid [[vertex_id]], constant MeshUniforms &u [[buffer(0)]]) {
    uint cols = uint(u.grid.x);
    uint rows = uint(u.grid.y);
    uint cell = vid / 6;
    uint2 corner = blackhole::corners[vid % 6];
    float2 uv = float2(float(cell % cols + corner.x) / float(cols),
                       float(cell / cols + corner.y) / float(rows));
    float2 p = u.frame.xy + uv * u.frame.zw;
    // The pull grows with the opening (fade.w ∝ presence): before swallowing starts, messages
    // near the hole already stretch towards it. Mostly upwards and never closer than the gap.
    {
        float2 dp = p - u.hole.xy;
        float dl = max(length(dp), 0.001);
        float R = max(u.hole.z, 1.0);
        float gap = max(dl - R, 0.0);
        float pull = min(u.fade.w * R * 0.7 * exp(-gap / (R * 1.4)), gap * 0.6);
        float2 dir = normalize(mix(dp / dl, float2(0.0, 1.0), 0.6));
        p -= dir * pull;
    }

    float2 center = u.hole.xy;
    float horizon = max(u.hole.z, 1.0);
    float sink = u.extra.x;
    float2 d = p - center;
    float rho = max(length(d), 0.001);
    float cosPhi = clamp(d.y / rho, 0.65, 1.0);
    float height = rho * blackhole::shapeFactor(rho, cosPhi, horizon, u.extra.z) - horizon;

    // New height: travelTime(D') = travelTime(D) − t. Newton's method from the constant-speed guess.
    float t = blackhole::easedTime(max(u.hole.w, 0.0), u.flow.w, u.extra.w);
    float reach = max(u.flow.z, 1.0);
    float speed = max(u.flow.x, 1.0);
    float goal = blackhole::travelTime(height, u.flow) - t;
    float landed = height - speed * t;
    for (int i = 0; i < 8; i++) {
        landed = clamp(landed, -sink - 40.0, height);
        float slope = 1.0 / (speed * (1.0 + u.flow.y * exp(-landed / reach)));
        landed -= (blackhole::travelTime(landed, u.flow) - goal) / slope;
    }
    landed = clamp(landed, -sink, height);

    float rhoNew = (landed + horizon) / pow(cosPhi, u.extra.z);
    for (int i = 0; i < 4; i++) {
        rhoNew = (landed + horizon) / blackhole::shapeFactor(rhoNew, cosPhi, horizon, u.extra.z);
    }
    float progress = clamp(1.0 - (landed + sink) / max(height + sink, 1.0), 0.0, 1.0);
    float angle = atan2(d.y, d.x) + u.extra.y * progress * progress;
    float2 q = center + float2(cos(angle), sin(angle)) * rhoNew;

    // Over the ring the message heats up with its light and dissolves only at the horizon.
    float rr = rhoNew / horizon;
    float heat = 1.0 - smoothstep(u.fade.y, u.fade.x, rr);
    float visible = smoothstep(u.fade.y, u.fade.y + 0.18, rr);
    if (landed <= -sink + 0.5) { visible = 0.0; }
    float maxLod = log2(max(u.fade.z * u.view.z, 1.0));

    MeshOut out;
    out.position = float4(q.x / u.view.x * 2.0 - 1.0, 1.0 - q.y / u.view.y * 2.0, 0.0, 1.0);
    out.uv = uv;
    out.alpha = visible;
    out.lod = heat * heat * maxLod;
    out.heat = heat;
    return out;
}

fragment half4 blackHoleMeshFragment(MeshOut in [[stage_in]], texture2d<half> texture [[texture(0)]],
                                     sampler smp [[sampler(0)]]) {
    half4 color = texture.sample(smp, in.uv, level(in.lod));
    // Heat: the color goes into the warm light of the ring (white → gold), merging with it.
    float h = in.heat;
    half3 glow = half3(mix(float3(1.0, 0.84, 0.55), float3(1.0, 0.97, 0.9), h * h));
    color.rgb = mix(color.rgb, glow * color.a, half(smoothstep(0.0, 0.85, h) * 0.85))
              + glow * color.a * half(h * 0.35);
    return color * half(in.alpha);
}
