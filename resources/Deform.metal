#include <metal_stdlib>
using namespace metal;

// Lattice coordinates s; world = M s. Each op maps s -> A s + t.
struct Op {
    float4 A, Ainv;
    float2 t, pad;
};

struct Group {
    float4 M, Minv;
    uint count, hex;
    float sigma;
    uint pad;
    Op ops[12];
};

// Tile centres for site i and op k at [i * 12 + k]: xy = op(site), z = canonical op whose tile
// this is, translated by shift.xy. Colours per (site, canonical op) and translation parity.
struct Style {
    float4 centre[24];
    int4 shift[24];
    uint4 color[24];
    float4 tones[6];
    float4 ink, paper;
    float4 eye[2]; // xy: world offset from the site, z: radius (0: symmetric tile), w: pupil
    float4 line;   // x: half width, y: one texel in world units, z: number of sites
};

struct View {
    float2 center, span;
    float pixels, dot;
    uint original, handles;
    int selected;
    float period; // lattice cells across the material's supercell
    uint pad[2];
    float4 targets[8];
};

static float2 mul(float4 m, float2 v) {
    return float2(m.x * v.x + m.y * v.y, m.z * v.x + m.w * v.y);
}

static float square_weight(float2 d, float sigma) {
    float2 t = fract(d);
    float2 axes = (exp2(-sigma * t) + exp2(-sigma * (1.0f - t))) / (1.0f - exp2(-sigma));
    return axes.x * axes.y;
}

static float weight(float2 d, float sigma, bool hex) {
    if (!hex)
        return square_weight(d, sigma);
    // The square closed form symmetrized over the hexagonal point group (see Core.cpp).
    return (square_weight(d, sigma) + square_weight(float2(-d.y, d.x - d.y), sigma) +
            square_weight(float2(-d.x + d.y, -d.x), sigma) +
            square_weight(float2(d.y, d.x), sigma) + square_weight(float2(d.x - d.y, -d.y), sigma) +
            square_weight(float2(-d.x, -d.x + d.y), sigma)) /
           6.0f;
}

// B(p) = Σ_g w(p - g h) A_g for every mesh point and handle.
kernel void build_basis(device const float2 *points [[buffer(0)]],
                        device const float2 *handles [[buffer(1)]],
                        device float4 *basis [[buffer(2)]], constant uint &count [[buffer(3)]],
                        constant Group &group [[buffer(4)]], constant uint &total [[buffer(5)]],
                        uint id [[thread_position_in_grid]]) {
    if (id >= total)
        return;
    float2 p = points[id % count], h = handles[id / count];
    float4 b = 0;
    for (uint k = 0; k < group.count; ++k) {
        Op op = group.ops[k];
        b += weight(p - (mul(op.A, h) + op.t), group.sigma, group.hex != 0) * op.A;
    }
    basis[id] = b;
}

struct ScreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex ScreenOut screen_vertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y)};
}

// The undeformed material on a 2 × 2 supercell: Dirichlet tiles, outlines and eyes.
fragment float4 art_fragment(ScreenOut in [[stage_in]], constant Group &g [[buffer(0)]],
                             constant Style &style [[buffer(1)]]) {
    float2 s = in.uv * 2;
    uint sites = uint(style.line.z);
    float best = INFINITY;
    uint bi = 0;
    float2 bn = 0, bc = 0;
    for (uint i = 0; i < sites * 12; i += 12)
        for (uint k = 0; k < g.count; ++k) {
            float2 p = style.centre[i + k].xy, base = round(s - p);
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx) {
                    float2 n = base + float2(dx, dy), c = p + n;
                    float d = length(mul(g.M, s - c));
                    if (d < best) {
                        best = d;
                        bi = i + k;
                        bn = n;
                        bc = c;
                    }
                }
        }
    float edge = INFINITY;
    for (uint i = 0; i < sites * 12; i += 12)
        for (uint k = 0; k < g.count; ++k) {
            float2 p = style.centre[i + k].xy, base = round(s - p);
            for (int dy = -1; dy <= 1; ++dy)
                for (int dx = -1; dx <= 1; ++dx) {
                    float2 c = p + base + float2(dx, dy);
                    float span = length(mul(g.M, c - bc));
                    if (span < 1e-4f)
                        continue;
                    float d = length(mul(g.M, s - c));
                    edge = min(edge, (d * d - best * best) / (2 * span));
                }
        }
    uint site = bi / 12, op = bi % 12, canonical = site * 12 + uint(style.centre[bi].z);
    int2 parity = (int2(bn) + style.shift[bi].xy) & 1;
    float3 color = style.tones[style.color[canonical][parity.x + 2 * parity.y]].rgb;
    float aa = style.line.y, lw = style.line.x;
    float4 eye = style.eye[site];
    if (eye.z > 0) {
        Op o = g.ops[op];
        float2 local = mul(o.Ainv, s - bn - o.t);
        float r = length(mul(g.M, local - style.centre[site * 12].xy) - eye.xy);
        color = mix(color, style.paper.rgb, 1 - smoothstep(eye.z - aa, eye.z + aa, r));
        color =
            mix(color, style.ink.rgb, 1 - smoothstep(lw * .8 - aa, lw * .8 + aa, abs(r - eye.z)));
        color = mix(color, style.ink.rgb, 1 - smoothstep(eye.w - aa, eye.w + aa, r));
    } else {
        float r = length(mul(g.M, s - bc));
        color = mix(color, style.ink.rgb, 1 - smoothstep(eye.w - aa, eye.w + aa, r));
    }
    // A faint inner contour, like the second cut of a woodblock.
    float inner = abs(edge - lw * 4.5f);
    color = mix(color, style.ink.rgb, .28f * (1 - smoothstep(lw * .3f - aa, lw * .3f + aa, inner)));
    color = mix(color, style.ink.rgb, 1 - smoothstep(lw - aa, lw + aa, edge));
    return float4(color, 1);
}

struct GridVertex {
    float2 source;
    float2 mapped;
};

struct TileOut {
    float4 position [[position]];
    float2 uv;
};

// (n + 2)² translated copies of the deformed unit cell cover the n × n supercell.
vertex TileOut tile_vertex(device const GridVertex *vertices [[buffer(0)]],
                           constant uint &n [[buffer(1)]], uint id [[vertex_id]],
                           uint instance [[instance_id]]) {
    GridVertex v = vertices[id];
    float2 offset = float2(int(instance % (n + 2)) - 1, int(instance / (n + 2)) - 1);
    float2 p = (v.mapped + offset) / float(n);
    return {float4(2 * p.x - 1, 1 - 2 * p.y, 0, 1), (v.source + offset) / float(n)};
}

fragment float4 tile_fragment(TileOut in [[stage_in]], texture2d<float> artwork [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    return artwork.sample(s, in.uv);
}

static float3 disc(float3 color, float r, float radius, float border, float3 fill, float3 edge,
                   float opacity) {
    float outer = clamp(radius + .5f - r, 0.0f, 1.0f),
          inner = clamp(radius - border + .5f - r, 0.0f, 1.0f);
    color = mix(color, edge, outer * opacity);
    return mix(color, fill, inner * opacity);
}

fragment float4 screen_fragment(ScreenOut in [[stage_in]], constant View &view [[buffer(0)]],
                                constant Group &g [[buffer(1)]],
                                texture2d<float> deformed [[texture(0)]],
                                texture2d<float> original [[texture(1)]]) {
    constexpr sampler sm(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float2 s = mul(g.Minv, view.center + (in.uv - .5f) * view.span);
    float3 color =
        view.original ? original.sample(sm, s / view.period).rgb : deformed.sample(sm, s / view.period).rgb;
    const float3 white = float3(1), black = float3(.012f);
    for (uint i = 0; i < view.handles; ++i)
        for (uint k = 0; k < g.count; ++k) {
            Op op = g.ops[k];
            float2 d = s - (mul(op.A, view.targets[i].xy) + op.t);
            float r = length(mul(g.M, d - round(d))) * view.pixels;
            bool primary = k == 0, selected = int(i) == view.selected;
            float radius = (primary ? 6.5f : 4.0f) * view.dot;
            if (r > radius + 1)
                continue;
            color = disc(color, r, radius, 1.5f * view.dot, selected ? black : white,
                         selected ? white : black, primary ? 1.0f : .75f);
        }
    return float4(color, 1);
}
