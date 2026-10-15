/* Swarm Portraits — generative renderer (v0.1, smooth edges)
   Same as v0.1 except the final composite: each output pixel weighs the four nearest work-canvas pixels,
   so colour boundaries and ink lines follow smooth curves instead of the 620 × 877 grid's 4-pixel steps.
   Original algorithm. Pipeline: scene -> glitch -> soften -> texture -> posterize -> regions -> ink outlines -> watercolor fill -> paper. */
const SwarmArt = (() => {
  const W = 620, H = 877; // A-series paper ratio (1:1.414)

  const PALETTES = [
    { name: 'Ember',      cols: ['#e8452c','#f26b3a','#f4a582','#f7e6c9','#fbf6ea','#2c4a5e','#4f7a8a','#8fb3b8','#1b2a3a','#c9cfc9','#d8b25a','#7a2f2a'] },
    { name: 'Rosewater',  cols: ['#e9a3a8','#f2c4c0','#d9727b','#f08a4b','#f5d0a0','#f7ecd8','#8a8fa3','#4a5a74','#26344d','#b9c4c2','#6f8f86','#c96a5a'] },
    { name: 'Peach Dusk', cols: ['#f6b48f','#f08a5d','#f7c65c','#fde6c8','#fff4e3','#253a7a','#3c4fa8','#1a2250','#d9473f','#3aa39a','#76b852','#a9b7e8'] },
    { name: 'Lagoon',     cols: ['#1f6f78','#3fa7a3','#a8dadc','#f1faee','#e63946','#f4a261','#264653','#e9c46a','#8d99ae','#2a2f45','#fbe8d3','#9c3d54'] },
    { name: 'Ochre Ink',  cols: ['#d4a017','#b5651d','#7a2e1f','#f3e3c3','#2e3b4e','#5c7a99','#9fb1c2','#e7d7b0','#c2452d','#3e5e3a','#fbf3e2','#d98c5f'] },
    { name: 'Signal',     cols: ['#d7263d','#f46036','#ffd166','#fff8e7','#2e294e','#1b998b','#c5d86d','#e9e3d5','#3d5a80','#98c1d9','#ee6c4d','#293241'] },
  ];

  // ---------- utilities ----------
  function hashStr(s) { let h = 2166136261 >>> 0; s = String(s); for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
  function rng(a) { return function () { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
  function ihash(x, y, s) { let h = (Math.imul(x | 0, 374761393) + Math.imul(y | 0, 668265263) + Math.imul(s | 0, 2147483647)) | 0; h = Math.imul(h ^ (h >>> 13), 1274126177); return ((h ^ (h >>> 16)) >>> 0) / 4294967296; }
  function makeNoise(seed) {
    const R = rng(seed), perm = new Uint8Array(512), vals = new Float32Array(256);
    for (let i = 0; i < 256; i++) { perm[i] = i; vals[i] = R(); }
    for (let i = 255; i > 0; i--) { const j = (R() * (i + 1)) | 0; const t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
    for (let i = 0; i < 256; i++) perm[i + 256] = perm[i];
    const lat = (x, y) => vals[perm[(perm[x & 255] + y) & 255]];
    return (x, y) => {
      const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
      const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
      const a = lat(xi, yi), b = lat(xi + 1, yi), c = lat(xi, yi + 1), d = lat(xi + 1, yi + 1);
      return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v;
    };
  }
  const clamp = (v, a, b) => v < a ? a : v > b ? b : v;
  const sstep = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
  function hexRgb(h) { const n = parseInt(h.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; }
  function rgbStr(c) { return `rgb(${c[0] | 0},${c[1] | 0},${c[2] | 0})`; }
  function shade(c, k) { return k >= 0 ? c.map(v => v + (255 - v) * k) : c.map(v => v * (1 + k)); }

  // ---------- parameters ----------
  function deriveTraits(p) {
    const seedStr = p.mode === 'swarm' ? 'swarm:' + p.seed : 'seat:' + p.seat;
    const seed = hashStr(seedStr);
    const R = rng(seed);
    const accepted = +p.accepted || 0, rate = clamp((+p.rate || 0) / 100, 0, 1), turns = +p.turns || 0, hours = +p.hours || 0;
    const t = {
      seed, seedStr,
      structure: clamp(Math.log10(accepted + 1) / Math.log10(4000), 0, 1),
      density: clamp(Math.log10(turns + 1) / Math.log10(30000), 0, 1),
      depth: clamp(hours / 60, 0, 1),
      glitch: clamp(0.16 + (1 - rate) * 6, 0, 1),
      texture: 0.35 + R() * 0.65,
      outdated: !!p.outdated,
      paletteIdx: hashStr(seedStr + ':palette') % PALETTES.length,
    };
    let scene = p.scene || 'auto';
    if (scene === 'auto') {
      if (p.mode === 'swarm') { const r = R(); scene = r < 0.45 ? 'city' : r < 0.75 ? 'corridor' : r < 0.90 ? 'tunnel' : r < 0.97 ? 'sketch' : 'blueprint'; }
      else if (accepted < 25) scene = 'sketch';
      else if (accepted >= 2500) scene = 'tunnel';
      else if (hours >= 15) scene = 'corridor';
      else scene = 'city';
    }
    if (p.mode === 'swarm') { t.structure = 0.4 + R() * 0.6; t.density = 0.4 + R() * 0.6; t.depth = R(); t.glitch = 0.2 + R() * 0.5; }
    t.scene = scene;
    t.baseScene = ['city', 'corridor', 'tunnel'][hashStr(seedStr + ':base') % 3];
    t.colorFrac = clamp(0.12 + accepted / 25 * 0.28, 0.12, 0.4);
    if (scene === 'sketch' || scene === 'blueprint') { t.glitch = 0.22; t.texture *= 0.45; }
    if (scene === 'blueprint') t.colorFrac = 0.05; // Line Study: a sketch left mostly bare paper
    t.palette = PALETTES[t.paletteIdx];
    t.labels = {
      Type: p.mode === 'swarm' ? 'Swarm Portrait' : 'Agent Portrait',
      Scene: { city: 'Glitch City', corridor: 'Corridor', tunnel: 'Vortex', sketch: 'Sketch', blueprint: 'Line Study' }[scene],
      Palette: t.palette.name,
      Glitch: t.glitch < 0.3 ? 'Clean' : t.glitch < 0.6 ? 'Weathered' : 'Fractured',
      Density: t.density < 0.4 ? 'Sparse' : t.density < 0.75 ? 'Dense' : 'Teeming',
      Depth: t.depth < 0.3 ? 'Shallow' : t.depth < 0.65 ? 'Deep' : 'Abyssal',
      Paper: t.outdated ? 'Weathered' : 'Fresh',
    };
    if (p.mode !== 'swarm') Object.assign(t.labels, { Seat: '#' + p.seat, Accepted: String(accepted), Acceptance: Math.round(rate * 100) + '%', Turns: String(turns), Hours: String(hours) });
    return t;
  }

  // ---------- color picking ----------
  function makePicker(R, pal) {
    const cols = pal.cols.map(hexRgb);
    for (let i = cols.length - 1; i > 0; i--) { const j = (R() * (i + 1)) | 0; [cols[i], cols[j]] = [cols[j], cols[i]]; }
    const pick = (bias = 1.5) => cols[Math.min(cols.length - 1, (Math.pow(R(), bias) * cols.length) | 0)];
    return { cols, pick };
  }

  // ---------- scene primitives ----------
  function tiles(ctx, R, P, x, y, w, h, cell, keyP, sub) {
    const palSub = sub || [P.pick(), P.pick(), P.pick(), P.pick(1)];
    for (let yy = y; yy < y + h; yy += cell) for (let xx = x; xx < x + w; xx += cell) {
      const c = palSub[(R() * palSub.length) | 0];
      ctx.fillStyle = rgbStr(c); ctx.fillRect(xx, yy, cell + 0.5, cell + 0.5);
      if (cell >= 5 && R() < keyP) {
        ctx.fillStyle = rgbStr(shade(c, R() < 0.5 ? 0.35 : -0.35));
        const m = cell * 0.2; ctx.beginPath(); ctx.roundRect(xx + m, yy + m, cell - 2 * m, cell - 2 * m, cell * 0.2); ctx.fill();
      }
    }
  }
  function rings(ctx, R, P, cx, cy, rx, ry) {
    const a = P.pick(), b = shade(a, 0.3), c = P.pick();
    const n = 8 + (R() * 10) | 0;
    for (let k = n; k > 0; k--) {
      const s = k / n; ctx.fillStyle = rgbStr(k % 3 === 0 ? c : k % 2 ? a : b);
      ctx.beginPath(); ctx.ellipse(cx + (R() - 0.5) * 3, cy + (R() - 0.5) * 3, rx * s, ry * s, 0, 0, Math.PI * 2); ctx.fill();
    }
  }
  function quad(ctx, pts, col) { ctx.fillStyle = rgbStr(col); ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]); for (let i = 1; i < 4; i++) ctx.lineTo(pts[i][0], pts[i][1]); ctx.closePath(); ctx.fill(); }

  // split unit square into patches
  function patches(R, depthMax) {
    const out = [];
    (function split(x, y, w, h, d) {
      if (d >= depthMax || (d > 1 && R() < 0.3)) { out.push([x, y, w, h]); return; }
      if (w > h ? R() < 0.75 : R() < 0.25) { const s = 0.25 + R() * 0.5; split(x, y, w * s, h, d + 1); split(x + w * s, y, w * (1 - s), h, d + 1); }
      else { const s = 0.25 + R() * 0.5; split(x, y, w, h * s, d + 1); split(x, y + h * s, w, h * (1 - s), d + 1); }
    })(0, 0, 1, 1, 0);
    return out;
  }

  // ---------- scenes ----------
  function sceneCity(ctx, R, P, T) {
    ctx.fillStyle = rgbStr(P.cols[0]); ctx.fillRect(0, 0, W, H);
    const bands = 5 + (T.structure * 6) | 0;
    for (let i = 0; i < bands; i++) { ctx.fillStyle = rgbStr(P.pick()); ctx.fillRect(R() * W - 100, R() * H - 100, 100 + R() * 500, 60 + R() * 300); }
    const cellBase = Math.round(26 - T.density * 18);
    const nP = 3 + (T.structure * 8) | 0;
    for (let i = 0; i < nP; i++) {
      const w = 60 + R() * 260, h = 40 + R() * 200, x = R() * W - 30, y = R() * H - 30;
      tiles(ctx, R, P, x, y, w, h, Math.max(4, cellBase * (0.5 + R())), 0.4 + R() * 0.5);
    }
    const towers = 6 + (T.structure * 22) | 0;
    for (let i = 0; i < towers; i++) {
      const w = 8 + R() * 70 * (1.2 - T.density * 0.6), x = R() * W; let y = -20 + R() * H * 0.5;
      while (y < H) {
        const bh = 8 + R() * 110;
        if (R() < 0.35) tiles(ctx, R, P, x, y, w, bh, Math.max(4, cellBase * (0.4 + R() * 0.6)), 0.6);
        else { ctx.fillStyle = rgbStr(P.pick()); ctx.fillRect(x, y, w, bh); }
        y += bh;
      }
    }
    for (let i = 0; i < 2 + R() * 3; i++) rings(ctx, R, P, R() * W, R() * H, 20 + R() * 70, 30 + R() * 110);
  }

  function sceneCorridor(ctx, R, P, T) {
    const f = W * (0.42 + R() * 0.2), cx = W * (0.35 + R() * 0.3), cy = H * (0.36 + R() * 0.12);
    const z0 = 0.3, z1 = 3 + T.depth * 10, floorY = -0.75, ceilY = 1.6, hw = 1.1;
    const pr = (X, Y, Z) => [cx + f * X / Z, cy - f * Y / Z];
    ctx.fillStyle = rgbStr(P.pick()); ctx.fillRect(0, 0, W, H);
    const cellMul = 1.4 - T.density * 0.8;
    function plane(map, rot) {
      for (const [px, py, pw, ph] of patches(R, 4)) {
        const style = R();
        const sub = [P.pick(), P.pick(), P.pick(), P.pick(1)];
        let nu, nv;
        if (style < 0.3) { nu = Math.max(2, (pw * 60 / cellMul) | 0); nv = 1; }          // stripes
        else if (style < 0.42) { nu = 1; nv = 1; }                                         // solid
        else { nu = Math.max(1, (pw * 34 / cellMul) | 0); nv = Math.max(1, (ph * 34 / cellMul * (rot ? 1 : 2.5)) | 0); }
        const keys = style > 0.6;
        for (let i = 0; i < nu; i++) for (let j = 0; j < nv; j++) {
          const u0 = px + pw * i / nu, u1 = px + pw * (i + 1) / nu, v0 = py + ph * j / nv, v1 = py + ph * (j + 1) / nv;
          const c = sub[(R() * sub.length) | 0];
          quad(ctx, [map(u0, v0), map(u1, v0), map(u1, v1), map(u0, v1)], c);
          if (keys && R() < 0.7) {
            const du = (u1 - u0) * 0.2, dv = (v1 - v0) * 0.2;
            quad(ctx, [map(u0 + du, v0 + dv), map(u1 - du, v0 + dv), map(u1 - du, v1 - dv), map(u0 + du, v1 - dv)], shade(c, R() < 0.5 ? 0.3 : -0.3));
          }
        }
      }
    }
    // back wall, side walls, floor
    plane((u, v) => pr(-hw + u * 2 * hw, ceilY - v * (ceilY - floorY), z1), true);
    plane((u, v) => pr(-hw, ceilY - v * (ceilY - floorY), z0 + u * (z1 - z0) ** 1 ), false);
    plane((u, v) => pr(hw, ceilY - v * (ceilY - floorY), z0 + u * (z1 - z0)), false);
    plane((u, v) => pr(-hw + u * 2 * hw, floorY, z0 + v * (z1 - z0)), true);
    // columns, far to near
    const n = 2 + (T.structure * 6) | 0, cols = [];
    for (let i = 0; i < n; i++) cols.push({ X: (R() < 0.5 ? -1 : 1) * (0.3 + R() * 0.65), Z: 0.8 + R() * (z1 * 0.6), w: 0.1 + R() * 0.25 });
    cols.sort((a, b) => b.Z - a.Z);
    for (const c of cols) {
      const a = pr(c.X - c.w / 2, ceilY, c.Z), b = pr(c.X + c.w / 2, floorY, c.Z);
      // side face toward center
      const sx = c.X < 0 ? c.X + c.w / 2 : c.X - c.w / 2, d = c.w;
      quad(ctx, [pr(sx, ceilY, c.Z), pr(sx, ceilY, c.Z + d), pr(sx, floorY, c.Z + d), pr(sx, floorY, c.Z)], shade(P.pick(), -0.25));
      ctx.save(); ctx.beginPath(); ctx.rect(a[0], a[1], b[0] - a[0], b[1] - a[1]); ctx.clip();
      ctx.fillStyle = rgbStr(P.pick()); ctx.fillRect(a[0], a[1], b[0] - a[0], b[1] - a[1]);
      const w = b[0] - a[0], h = b[1] - a[1];
      for (let k = 0; k < 1 + R() * 3; k++) rings(ctx, R, P, a[0] + w * (0.3 + R() * 0.4), a[1] + h * R(), w * (0.4 + R() * 0.5), h * (0.1 + R() * 0.25));
      ctx.restore();
    }
  }

  function sceneTunnel(ctx, R, P, T) {
    const img = ctx.createImageData(W, H), d = img.data;
    const cx = W * (0.4 + R() * 0.2), cy = H * (0.4 + R() * 0.2);
    const pexp = 1.8 + R() * 4, twist = (R() - 0.5) * 1.6;
    const N = Math.round(14 + T.density * 34), M = 1.4 + T.density * 2.5;
    const fog = R() < 0.5 ? P.cols.slice().sort((a, b) => (a[0] + a[1] + a[2]) - (b[0] + b[1] + b[2]))[0] : P.cols[0];
    const s = T.seed & 0xffff, maxD = 3 + T.depth * 9;
    const subs = []; for (let i = 0; i < 16; i++) subs.push([P.pick(), P.pick(), P.pick(), P.pick(1)]);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const dx = (x - cx) / W, dy = (y - cy) / W;
      const r = Math.pow(Math.pow(Math.abs(dx), pexp) + Math.pow(Math.abs(dy), pexp), 1 / pexp) + 1e-4;
      const depth = 0.09 / r;
      const ang = Math.atan2(dy, dx) / (Math.PI * 2) + 0.5 + twist * Math.log(depth + 1) * 0.15;
      const u = ang * N, v = depth * M * 6;
      const iu = Math.floor(u), iv = Math.floor(v);
      const pu = Math.floor(iu / 3), pv = Math.floor(iv / 2);
      const sub = subs[(ihash(pu, pv, s) * 16) | 0];
      let c = sub[(ihash(iu, iv, s + 1) * 4) | 0];
      const style = ihash(pu, pv, s + 2);
      const fu = u - iu, fv = v - iv;
      if (style > 0.55 && fu > 0.2 && fu < 0.8 && fv > 0.2 && fv < 0.8) c = shade(c, style > 0.78 ? 0.32 : -0.32);
      if (style < 0.12) c = sub[0];
      const tf = Math.pow(clamp(depth / maxD, 0, 1), 1.3);
      const o = (y * W + x) * 4;
      d[o] = c[0] + (fog[0] - c[0]) * tf; d[o + 1] = c[1] + (fog[1] - c[1]) * tf; d[o + 2] = c[2] + (fog[2] - c[2]) * tf; d[o + 3] = 255;
    }
    ctx.putImageData(img, 0, 0);
    // segmented arcs
    const arcs = 2 + (T.structure * 5) | 0;
    for (let i = 0; i < arcs; i++) {
      const ax = R() * W, ay = R() * H, rad = 80 + R() * 300, th = 18 + R() * 50, a0 = R() * Math.PI * 2, span = 0.6 + R() * 1.8, segs = 6 + (R() * 20) | 0;
      for (let k = 0; k < segs; k++) {
        ctx.strokeStyle = rgbStr(P.pick()); ctx.lineWidth = th;
        ctx.beginPath(); ctx.arc(ax, ay, rad, a0 + span * k / segs, a0 + span * (k + 1) / segs + 0.01); ctx.stroke();
      }
    }
    // edge slabs
    for (let i = 0; i < 2 + R() * 4; i++) {
      const w = 40 + R() * 160, h = 80 + R() * 260, x = R() < 0.5 ? -20 + R() * 60 : W - w + 20 - R() * 60, y = R() * H - 40;
      if (R() < 0.5) { ctx.fillStyle = rgbStr(P.pick()); ctx.fillRect(x, y, w, h); }
      else tiles(ctx, R, P, x, y, w, h, 10 + R() * 20, 0.5);
    }
  }

  // ---------- pixel stages ----------
  function glitch(d, R, g, N2) {
    const row = new Uint8ClampedArray(W * 4);
    const nb = (2 + g * 16) | 0;
    for (let i = 0; i < nb; i++) {
      const y0 = (R() * H) | 0, h = (3 + R() * 30) | 0, dx = ((R() - 0.5) * (30 + 140 * g)) | 0;
      for (let y = y0; y < Math.min(H, y0 + h); y++) {
        row.set(d.subarray(y * W * 4, (y + 1) * W * 4));
        for (let x = 0; x < W; x++) { const sx = ((x - dx) % W + W) % W; d.set(row.subarray(sx * 4, sx * 4 + 4), (y * W + x) * 4); }
      }
    }
    const nd = (3 + g * 12) | 0;
    for (let i = 0; i < nd; i++) {
      const x0 = (R() * W) | 0, w = (8 + R() * 150) | 0, ys = (R() * H * 0.85) | 0, L = (20 + R() * 260) * (0.5 + g), dir = R() < 0.72 ? 1 : -1;
      for (let x = x0; x < Math.min(W, x0 + w); x++) {
        const len = (L * (0.35 + 0.9 * N2(x * 0.06, i * 7.1)) * (0.7 + 0.3 * R())) | 0;
        const so = (ys * W + x) * 4, r = d[so], gg = d[so + 1], b = d[so + 2];
        for (let k = 1; k < len; k++) {
          const y = ys + k * dir; if (y < 0 || y >= H) break;
          const o = (y * W + x) * 4; d[o] = r; d[o + 1] = gg; d[o + 2] = b;
        }
      }
    }
  }
  function blur(d, rad) {
    const tmp = new Float32Array(W * H * 3);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      let r = 0, g = 0, b = 0, n = 0;
      for (let k = -rad; k <= rad; k++) { const xx = clamp(x + k, 0, W - 1), o = (y * W + xx) * 4; r += d[o]; g += d[o + 1]; b += d[o + 2]; n++; }
      const t = (y * W + x) * 3; tmp[t] = r / n; tmp[t + 1] = g / n; tmp[t + 2] = b / n;
    }
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      let r = 0, g = 0, b = 0, n = 0;
      for (let k = -rad; k <= rad; k++) { const yy = clamp(y + k, 0, H - 1), t = (yy * W + x) * 3; r += tmp[t]; g += tmp[t + 1]; b += tmp[t + 2]; n++; }
      const o = (y * W + x) * 4; d[o] = r / n; d[o + 1] = g / n; d[o + 2] = b / n;
    }
  }

  function render(canvas, params, opts = {}) {
    const S = opts.scale || 4;
    const T = deriveTraits(params);
    const R = rng(T.seed ^ 0x9e3779b9);
    const P = makePicker(R, T.palette);
    canvas.width = W * S; canvas.height = H * S;

    const work = document.createElement('canvas'); work.width = W; work.height = H;
    const ctx = work.getContext('2d', { willReadFrequently: true });
    ({ city: sceneCity, corridor: sceneCorridor, tunnel: sceneTunnel })[T.scene === 'sketch' || T.scene === 'blueprint' ? T.baseScene : T.scene](ctx, R, P, T);
    const id = ctx.getImageData(0, 0, W, H), d = id.data;
    const N1 = makeNoise(T.seed + 1), N2 = makeNoise(T.seed + 2), N3 = makeNoise(T.seed + 3), N4 = makeNoise(T.seed + 4);
    glitch(d, R, T.glitch, N2);
    blur(d, 1);
    // organic texture -> squiggly contours after posterizing
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const m = sstep(0.4, 0.75, N3(x / 110, y / 110)) * T.texture;
      const l = (N1(x / 24, y / 24) - 0.5) * 34 + (N4(x / 5.5, y / 5.5) - 0.5) * 80 * m;
      const o = (y * W + x) * 4; d[o] += l; d[o + 1] += l; d[o + 2] += l;
    }
    // posterize to palette + tints
    const Q = [];
    for (const c of P.cols) { Q.push(c, shade(c, 0.28), shade(c, -0.28)); }
    const cache = new Int16Array(32768).fill(-1), idx = new Uint8Array(W * H);
    for (let i = 0, o = 0; i < W * H; i++, o += 4) {
      const key = (d[o] >> 3) << 10 | (d[o + 1] >> 3) << 5 | (d[o + 2] >> 3);
      let q = cache[key];
      if (q < 0) {
        let best = 1e9; const r = d[o], g = d[o + 1], b = d[o + 2];
        for (let k = 0; k < Q.length; k++) { const dr = r - Q[k][0], dg = g - Q[k][1], db = b - Q[k][2]; const e = dr * dr * 2 + dg * dg * 4 + db * db * 3; if (e < best) { best = e; q = k; } }
        cache[key] = q;
      }
      idx[i] = q;
    }
    // majority filter (removes specks)
    for (let pass = 0; pass < 2; pass++) {
      const src = idx.slice(), cnt = new Uint8Array(Q.length);
      for (let y = 1; y < H - 1; y++) for (let x = 1; x < W - 1; x++) {
        const i = y * W + x; let bestK = src[i], bestC = 0;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const k = src[i + dy * W + dx]; cnt[k]++; if (cnt[k] > bestC) { bestC = cnt[k]; bestK = k; } }
        if (cnt[src[i]] < 4) idx[i] = bestK;
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) cnt[src[i + dy * W + dx]] = 0;
      }
    }
    // connected regions
    const label = new Int32Array(W * H).fill(-1), stack = new Int32Array(W * H); let nl = 0;
    for (let s0 = 0; s0 < W * H; s0++) {
      if (label[s0] >= 0) continue;
      const c = idx[s0]; let sp = 0; stack[sp++] = s0; label[s0] = nl;
      while (sp) {
        const i = stack[--sp], x = i % W;
        if (x > 0 && label[i - 1] < 0 && idx[i - 1] === c) { label[i - 1] = nl; stack[sp++] = i - 1; }
        if (x < W - 1 && label[i + 1] < 0 && idx[i + 1] === c) { label[i + 1] = nl; stack[sp++] = i + 1; }
        if (i >= W && label[i - W] < 0 && idx[i - W] === c) { label[i - W] = nl; stack[sp++] = i - W; }
        if (i < W * H - W && label[i + W] < 0 && idx[i + W] === c) { label[i + W] = nl; stack[sp++] = i + W; }
      }
      nl++;
    }
    const size = new Int32Array(nl); for (let i = 0; i < W * H; i++) size[label[i]]++;
    for (let i = 0; i < W * H; i++) if (size[label[i]] < 7) {
      const nb = [i - 1, i + 1, i - W, i + W];
      for (const j of nb) if (j >= 0 && j < W * H && size[label[j]] >= 7) { idx[i] = idx[j]; label[i] = label[j]; break; }
    }
    // edge fields
    const Bx = new Float32Array(W * H), By = new Float32Array(W * H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const i = y * W + x;
      if (x < W - 1 && idx[i] !== idx[i + 1]) Bx[i] = 1;
      if (y < H - 1 && idx[i] !== idx[i + W]) By[i] = 1;
    }
    // per-region watercolor tint + mottling field
    const tint = new Float32Array(nl); const TR = rng(T.seed + 99);
    for (let k = 0; k < nl; k++) tint[k] = 0.94 + TR() * 0.1;
    const N5 = makeNoise(T.seed + 5), N6 = makeNoise(T.seed + 6);
    const mott = new Float32Array(W * H);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) mott[y * W + x] = (N5(x / 9, y / 9) - 0.5) * 0.12 + (N6(x / 40, y / 40) - 0.5) * 0.08;
    const desat = T.outdated ? 0.4 : 0, paperAmt = T.outdated ? 1.6 : 1;
    const sketch = T.scene === 'sketch' || T.scene === 'blueprint', colorOn = new Uint8Array(nl), CR = rng(T.seed + 31);
    for (let k = 0; k < nl; k++) colorOn[k] = CR() < T.colorFrac ? 1 : 0;
    const paperC = [242, 238, 228], inkC = sketch ? [58, 56, 70] : [26, 22, 28];
    // final composite
    const out = canvas.getContext('2d'); const OW = W * S, OH = H * S;
    const oimg = out.createImageData(OW, OH), od = oimg.data;
    const Qf = Q.map(c => c.slice());
    const GR = rng(T.seed + 7);
    const samp = (F, u, v) => {
      const x0 = Math.floor(u), y0 = Math.floor(v), fx = u - x0, fy = v - y0;
      const g = (xx, yy) => (xx < 0 || yy < 0 || xx >= W || yy >= H) ? 0 : F[yy * W + xx];
      return (g(x0, y0) * (1 - fx) + g(x0 + 1, y0) * fx) * (1 - fy) + (g(x0, y0 + 1) * (1 - fx) + g(x0 + 1, y0 + 1) * fx) * fy;
    };
    const fiberN = makeNoise(T.seed + 8);
    // Smooth edges: weigh the four work pixels around each output pixel by distance, take the palette
    // index with the most weight, and put ink where the two strongest indices are nearly balanced.
    // Ink is solid where the two strongest indices are within INK_CORE of each other and fades out by
    // INK_EDGE: about one work pixel wide, like the original lines.
    const INK_CORE = 0.3, INK_EDGE = 0.75;
    for (let oy = 0; oy < OH; oy++) {
      const v = (oy + 0.5) / S - 0.5, y0 = Math.floor(v), fy = v - y0;
      const ya = Math.max(0, Math.min(H - 1, y0)), yb = Math.max(0, Math.min(H - 1, y0 + 1));
      for (let ox = 0; ox < OW; ox++) {
        const u = (ox + 0.5) / S - 0.5, x0 = Math.floor(u), fx = u - x0;
        const xa = Math.max(0, Math.min(W - 1, x0)), xb = Math.max(0, Math.min(W - 1, x0 + 1));
        const n0 = ya * W + xa, n1 = ya * W + xb, n2 = yb * W + xa, n3 = yb * W + xb;
        const w0 = (1 - fx) * (1 - fy), w1 = fx * (1 - fy), w2 = (1 - fx) * fy, w3 = fx * fy;
        // Sum weights per palette index (at most four distinct values).
        const k0 = idx[n0], k1 = idx[n1], k2 = idx[n2], k3 = idx[n3];
        let s0 = w0, s1 = 0, s2 = 0, s3 = 0;
        if (k1 === k0) s0 += w1; else s1 = w1;
        if (k2 === k0) s0 += w2; else if (k2 === k1) s1 += w2; else s2 = w2;
        if (k3 === k0) s0 += w3; else if (k3 === k1) s1 += w3; else if (k3 === k2) s2 += w3; else s3 = w3;
        let best = s0, bestK = k0, second = 0;
        for (const [sv, kv] of [[s1, k1], [s2, k2], [s3, k3]]) {
          if (sv > best) { second = best; best = sv; bestK = kv; } else if (sv > second) second = sv;
        }
        // The pixel that carries the winning index (and its region, tint and mottling): the heaviest one.
        let i = n0, wi = -1;
        if (k0 === bestK && w0 > wi) { i = n0; wi = w0; }
        if (k1 === bestK && w1 > wi) { i = n1; wi = w1; }
        if (k2 === bestK && w2 > wi) { i = n2; wi = w2; }
        if (k3 === bestK && w3 > wi) { i = n3; wi = w3; }
        const lab = label[i];
        const c = (sketch && !colorOn[lab]) ? paperC : Qf[bestK]; const m = sketch && !colorOn[lab] ? 1 + mott[i] * 0.4 : tint[lab] + mott[i];
        let r = c[0] * m, g = c[1] * m, b = c[2] * m;
        if (desat) { const l = (r + g + b) / 3; r += (l - r) * desat; g += (l - g) * desat; b += (l - b) * desat; r = r * 0.95 + 10; g = g * 0.93 + 10; b = b * 0.88 + 6; }
        const a = second > 0 ? (1 - sstep(INK_CORE, INK_EDGE, best - second)) * 0.92 : 0;
        r = r * (1 - a) + inkC[0] * a; g = g * (1 - a) + inkC[1] * a; b = b * (1 - a) + inkC[2] * a;
        const grain = ((GR() - 0.5) * 16 + (fiberN(ox / 3, oy / 14) - 0.5) * 14) * paperAmt;
        const o = (oy * OW + ox) * 4;
        od[o] = r + grain; od[o + 1] = g + grain; od[o + 2] = b + grain * 0.9; od[o + 3] = 255;
      }
    }
    out.putImageData(oimg, 0, 0);
    T.regions = nl;
    return T;
  }

  return { render, deriveTraits, PALETTES, W, H };
})();

export default SwarmArt;
