#include <metal_stdlib>
using namespace metal;

// State: 0 dead, 1 anchored (letter, pre-thaw), 2 dynamic, 3 sleeping
struct Particle {
    float2 pos;
    float2 prev;
    float4 color;
    float bornAt;       // anchored-thaw time (seconds)
    float seed;
    uint state;
    uint neighbors;     // for AO at draw time
};

struct Uniforms {
    float now;
    float dt;
    float2 viewport;
    uint count;
    uint gridW;
    uint gridH;
    float h;            // cell size (= 2r)
    float r;            // particle radius
    float gravity;      // px/s^2
    float friction;     // Coulomb mu
    float2 cursor;
    float2 cursorVel;
    float2 tntPos;
    float tntT;         // seconds remaining; 0 = no fuse
};

// ─── Grid ──────────────────────────────────────────────────────────────

kernel void clearGrid(
    device atomic_int* heads [[buffer(0)]],
    constant Uniforms& u [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    if (id < u.gridW * u.gridH) {
        atomic_store_explicit(&heads[id], -1, memory_order_relaxed);
    }
}

kernel void buildGrid(
    device const Particle* p [[buffer(0)]],
    device atomic_int* heads [[buffer(1)]],
    device int* nexts [[buffer(2)]],
    constant Uniforms& u [[buffer(3)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= u.count) return;
    Particle q = p[id];
    if (q.state == 0) return;
    int gx = int(q.pos.x / u.h);
    int gy = int(q.pos.y / u.h);
    if (gx < 0 || gx >= int(u.gridW) || gy < 0 || gy >= int(u.gridH)) return;
    int h = gy * int(u.gridW) + gx;
    int prev = atomic_exchange_explicit(&heads[h], int(id), memory_order_relaxed);
    nexts[id] = prev;
}

// ─── Integrate (verlet, gravity, gentle wind) ──────────────────────────

kernel void integrate(
    device Particle* p [[buffer(0)]],
    constant Uniforms& u [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= u.count) return;
    Particle q = p[id];
    if (q.state == 0) return;

    // Anchored: hold in place until its thaw time. Then release —
    // straight down, no horizontal kick. Spread comes later from wind
    // (which ramps in with fall speed) and grain-grain collisions.
    if (q.state == 1) {
        if (u.now < q.bornAt) { return; }
        q.state = 2;
        q.prev = q.pos;
        // Imperceptible x noise (sub-pixel) so identical-x columns don't
        // pile into a perfect vertical bar from a cold start.
        float jx = (fract(q.seed * 91.7) - 0.5) * 0.08;
        q.prev.x -= jx;
    }

    // Sleeping: integration skipped. Collisions still see this particle
    // as a static neighbor; it can be woken by overlap or cursor.
    if (q.state == 3) {
        return;
    }

    float2 vel = q.pos - q.prev;
    float speed = length(vel);

    // Atmospheric wind: per-particle phase so different grains drift
    // different ways. Ramps in with downward speed — fresh-thawed grains
    // fall almost straight, then drift more as they pick up speed (no
    // perturb-feedback loop because we gate on vel.y, which gravity
    // drives, not wind).
    float phase = q.seed * 6.2831853;
    float2 wind;
    wind.x = sin(u.now * 0.35 + phase) * 1.4;
    wind.y = cos(u.now * 0.27 + phase * 1.7) * 0.35;
    float windRamp = clamp(vel.y * 0.55, 0.0, 1.0);
    vel += wind * u.dt * windRamp;

    vel.y += u.gravity * u.dt * u.dt;

    // Air drag. Slightly stronger on x to discourage sideways drift,
    // plus a quadratic term that bleeds energy from fast-moving grains
    // so a perturbation always decays.
    vel.x *= 0.992;
    vel.y *= 0.998;
    if (speed > 1.5) {
        float decay = 1.0 - clamp((speed - 1.5) * 0.02, 0.0, 0.08);
        vel *= decay;
    }

    // Terminal fall — a fine mist, not buckshot. Per-grain variance so
    // not every grain falls at the same exact rate (heavier ones lead).
    float maxFall = 4.5 + fract(q.seed * 11.731) * 1.2;
    if (vel.y > maxFall) vel.y = maxFall;
    // Hard speed ceiling so nothing ever runs away.
    float maxSpeed = 8.0;
    float vlen = length(vel);
    if (vlen > maxSpeed) vel *= (maxSpeed / vlen);

    q.prev = q.pos;
    q.pos += vel;

    p[id] = q;
}

// ─── Solve: symmetric Jacobi w/ Coulomb friction ───────────────────────

kernel void solve(
    device Particle* p [[buffer(0)]],
    device const atomic_int* heads [[buffer(1)]],
    device const int* nexts [[buffer(2)]],
    constant Uniforms& u [[buffer(3)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= u.count) return;
    Particle q = p[id];
    if (q.state == 0 || q.state == 1) return;

    int2 g = int2(q.pos / u.h);
    float minD = 2.0 * u.r;
    float minD2 = minD * minD;

    float2 disp = float2(0.0);
    float2 frictionVel = float2(0.0);
    int contacts = 0;
    int neighbors = 0;
    float2 myV = q.pos - q.prev;

    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            int gx = g.x + dx;
            int gy = g.y + dy;
            if (gx < 0 || gx >= int(u.gridW) || gy < 0 || gy >= int(u.gridH)) continue;
            int h = gy * int(u.gridW) + gx;
            int n = atomic_load_explicit(&heads[h], memory_order_relaxed);
            while (n != -1) {
                if (uint(n) != id) {
                    Particle r = p[n];
                    if (r.state != 0) {
                        float2 d = q.pos - r.pos;
                        float d2 = dot(d, d);
                        if (d2 > 1e-6 && d2 < minD2) {
                            neighbors++;
                            float dist = sqrt(d2);
                            float2 norm = d / dist;
                            float overlap = minD - dist;

                            // Symmetric Jacobi share. Anchored & sleeping
                            // neighbors take none of the correction (they're
                            // effectively kinematic), so I take all of it.
                            float share = (r.state == 2) ? 0.5 : 1.0;
                            disp += norm * overlap * share;
                            contacts++;

                            // Coulomb friction. Approximate normal impulse by
                            // overlap. Reduce tangential relative velocity by
                            // up to mu * |normalImpulse|.
                            float2 rV = r.pos - r.prev;
                            float2 relV = myV - rV;
                            float2 tang = relV - dot(relV, norm) * norm;
                            float tlen = length(tang);
                            if (tlen > 1e-4) {
                                float maxStop = u.friction * overlap;
                                float reduce = min(maxStop, tlen);
                                frictionVel -= (tang / tlen) * reduce * share;
                            }
                        }
                    }
                }
                n = nexts[n];
            }
        }
    }

    if (contacts > 0) {
        // Stiffness well below 1 keeps the solve stable in dense piles
        // and stops boundary-pinned stacks from rocketing upward.
        q.pos += disp * 0.55;
        // Apply friction by pulling prev toward pos along the friction vector,
        // which removes that component of velocity in the next integrate.
        q.prev -= frictionVel;
    }

    // Cursor: velocity-driven brush. Subtle — a fingertip, not a shovel.
    float2 toC = q.pos - u.cursor;
    float cd2 = dot(toC, toC);
    float cR = 32.0;
    float cs = length(u.cursorVel);
    if (cd2 > 0.01 && cd2 < cR * cR && cs > 1.0) {
        float fall = 1.0 - sqrt(cd2) / cR;
        q.pos += normalize(u.cursorVel) * fall * min(cs * 0.018, 0.45);
        if (q.state == 3) q.state = 2;
    }

    // Boundaries (no bounce — soft floor that accepts and holds).
    if (q.pos.y > u.viewport.y - u.r) {
        q.pos.y = u.viewport.y - u.r;
        // Strong tangential friction with the floor to encourage piling.
        q.prev.x = mix(q.prev.x, q.pos.x, 0.35);
    }
    if (q.pos.x < u.r) q.pos.x = u.r;
    if (q.pos.x > u.viewport.x - u.r) q.pos.x = u.viewport.x - u.r;

    // Wake sleepers whose support has been removed — e.g. when an anchored
    // letter beneath them thaws and falls away. Without this, grains that
    // landed on a still-solid letter stay frozen mid-air after it dissolves.
    if (q.state == 3 && neighbors < 2) {
        q.state = 2;
    }

    q.neighbors = uint(neighbors);
    p[id] = q;
}

// ─── Sleep: settle slow, well-supported grains ─────────────────────────

kernel void sleepCheck(
    device Particle* p [[buffer(0)]],
    constant Uniforms& u [[buffer(1)]],
    uint id [[thread_position_in_grid]])
{
    if (id >= u.count) return;
    Particle q = p[id];
    if (q.state != 2) return;
    float2 v = q.pos - q.prev;
    if (length(v) < 0.12 && q.neighbors >= 3) {
        q.state = 3;
        q.prev = q.pos; // zero velocity — total stillness
        p[id] = q;
    }
}

// ─── Render ────────────────────────────────────────────────────────────

struct VOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
    float occlusion;
    float anchored;
    float seed;
    float speed;
    float shimmer;
    uint state;
};

vertex VOut vsParticle(
    device const Particle* p [[buffer(0)]],
    constant Uniforms& u [[buffer(1)]],
    uint vid [[vertex_id]])
{
    Particle q = p[vid];
    VOut o;
    o.state = q.state;
    o.seed = q.seed;
    // Per-grain brightness variance — crushed-glass / particulate texture.
    float bright = 0.93 + 0.14 * fract(q.seed * 73.91);
    o.color = float4(q.color.rgb * bright, q.color.a);

    if (q.state == 0) {
        o.position = float4(-10, -10, 0, 1);
        o.pointSize = 0;
        o.occlusion = 1;
        o.anchored = 0;
        o.speed = 0;
        o.shimmer = 1.0;
        return o;
    }

    float2 ndc = (q.pos / u.viewport) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    o.position = float4(ndc, 0, 1);

    float baseSize = u.r * 2.6;
    float sizeJitter = 0.92 + 0.16 * fract(q.seed * 137.13);
    o.pointSize = max(baseSize * sizeJitter, 1.5);

    // Ambient occlusion from neighbor count: deep-in-pile grains darken.
    float n = float(q.neighbors);
    o.occlusion = clamp(1.0 - (n / 9.0) * 0.55, 0.45, 1.0);

    o.anchored = (q.state == 1) ? 1.0 : 0.0;
    o.speed = length(q.pos - q.prev);

    // Microscopic, meditative shimmer on settled & anchored grains —
    // ±2.5% slow brightness oscillation, per-grain phase. Brief asks
    // for it; previously only airborne grains caught light.
    float shim = 1.0;
    if (q.state == 3 || q.state == 1) {
        shim = 1.0 + sin(u.now * 0.55 + q.seed * 50.0) * 0.025;
    }
    o.shimmer = shim;

    // TNT heat tint
    if (u.tntT > 0.0) {
        float dT = distance(q.pos, u.tntPos);
        if (dT < 240.0) {
            float heat = 1.0 - dT / 240.0;
            o.color.rgb = mix(o.color.rgb, float3(1.0, 0.45, 0.12), heat * 0.85);
        }
    }

    return o;
}

fragment float4 fsParticle(
    VOut in [[stage_in]],
    float2 pc [[point_coord]])
{
    if (in.state == 0) discard_fragment();
    float2 c = pc - 0.5;
    float r2 = dot(c, c);
    if (r2 > 0.25) discard_fragment();

    // Sphere-ish normal for shading.
    float z = sqrt(max(0.0, 0.25 - r2));
    float3 n = normalize(float3(c.x, c.y, z));
    float3 L = normalize(float3(-0.35, -0.45, 0.82));
    float ndl = max(dot(n, L), 0.0);

    // Volcanic-ash shading: low ambient + lit highlight + AO + shimmer.
    float3 base = in.color.rgb;
    float3 lit = base * (0.55 + 0.55 * ndl) * in.occlusion * in.shimmer;

    // Subtle shimmer — only on grains that are airborne (catches the light
    // mid-fall, settles into stillness).
    if (in.speed > 0.4 && in.anchored < 0.5) {
        float t = fract(in.seed * 911.7);
        float spark = pow(max(dot(n, L), 0.0), 22.0) * (0.4 + 0.6 * t);
        lit += spark * 0.35;
    }

    // Soft point disc.
    float a = smoothstep(0.25, 0.18, r2);
    return float4(lit, a);
}
