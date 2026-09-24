// Game Duo host page for the Play! PS2 core. The iOS app talks to it through
// webkit.messageHandlers.duo (page → app) and window.duo (app → page).
import Play from './Play.js';

const post = (message) => window.webkit?.messageHandlers?.duo?.postMessage(message);
const config = window.duoConfig || {};
const MC = '/duo/mc0';
const HOST = '/duo/host';

window.addEventListener('error', (e) => post({ type: 'error', message: `${e.message} @${e.lineno}` }));
window.addEventListener('unhandledrejection', (e) => post({ type: 'error', message: String(e.reason) }));

const base64 = {
  encode(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  },
};

async function fetchBytes(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

function writeTree(M, root, files) {
  return Promise.all(files.map(async (entry) => {
    const data = await fetchBytes(entry.url);
    const full = `${root}/${entry.path}`;
    M.FS.mkdirTree(full.substring(0, full.lastIndexOf('/')));
    M.FS.writeFile(full, data);
  }));
}

// Memory card mirror: snapshot of path -> "size:mtime" for everything under MC.
function scanCard(M) {
  const result = new Map();
  const walk = (dir, rel) => {
    for (const name of M.FS.readdir(dir)) {
      if (name === '.' || name === '..' || name.startsWith('.')) continue;
      const full = `${dir}/${name}`;
      const path = rel ? `${rel}/${name}` : name;
      const stat = M.FS.stat(full);
      if (M.FS.isDir(stat.mode)) {
        result.set(path + '/', 'dir');
        walk(full, path);
      } else {
        result.set(path, `${stat.size}:${stat.mtime.getTime ? stat.mtime.getTime() : stat.mtime}`);
      }
    }
  };
  walk(MC, '');
  return result;
}

let M = null;
let started = false;
let paused = false;
let cardSnapshot = new Map();
let syncing = false;

function syncCard() {
  if (!M || syncing) return 0;
  syncing = true;
  let changes = 0;
  try {
    const now = scanCard(M);
    for (const [path, stamp] of now) {
      if (cardSnapshot.get(path) === stamp) continue;
      changes++;
      if (stamp === 'dir') post({ type: 'card', op: 'mkdir', path: path.slice(0, -1) });
      else post({ type: 'card', op: 'put', path, data: base64.encode(M.FS.readFile(`${MC}/${path}`)) });
    }
    for (const path of cardSnapshot.keys()) {
      if (now.has(path)) continue;
      changes++;
      post({ type: 'card', op: 'delete', path: path.endsWith('/') ? path.slice(0, -1) : path });
    }
    cardSnapshot = now;
  } catch (e) {
    post({ type: 'error', message: `card sync: ${e}` });
  } finally {
    syncing = false;
  }
  return changes;
}

let audio = null;
let audioStats = null;
let audioNode = null;

// Plays the core's audio ring (SH_Duo) through an AudioWorklet at the SPU2's native 48 kHz.
async function startAudio() {
  try {
    audio = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' });
    await audio.audioWorklet.addModule('duo_audio.js');
    const node = new AudioWorkletNode(audio, 'duo-ps2-audio', { numberOfInputs: 0, outputChannelCount: [2] });
    node.port.postMessage({ memory: M.duoMemory(), ring: M.duoAudioRing(), samplesOffset: M.duoAudioRingSamplesOffset() });
    node.port.onmessage = (e) => {
      if (e.data.captured) {
        // Float32 (-1...1), interleaved stereo at the context rate: keeps the full precision.
        post({ type: 'audioCapture', data: base64.encode(new Uint8Array(e.data.captured.buffer)) });
      } else audioStats = e.data;
    };
    audioNode = node;
    node.connect(audio.destination);
    resumeAudio();
  } catch (e) {
    post({ type: 'error', message: `audio: ${e}` });
  }
}

function resumeAudio() {
  if (audio && audio.state !== 'running') audio.resume().catch(() => {});
}

function suspendAudio() {
  if (audio && audio.state === 'running') audio.suspend().catch(() => {});
}

// The picture: the game's own black border (unused display rows/columns around many PS2 frames)
// is cropped away, and the content is fitted into the picture rectangle (uniform scale, centred). A
// clipping box (#pictureClip) hides the border and feathers the content's edges.
let picture = null;       // rectangle from the app (CSS pixels)
let content = null;       // where the frame's content is shown (CSS pixels)
let crop = { top: 0, bottom: 0, left: 0, right: 0 }; // fractions of the frame
const cropHistory = [];
let cropProbe = null;
let presentedFrames = 0;

function layoutPicture() {
  if (!picture) return;
  const { x, y, width: w, height: h } = picture;
  const ch = 1 - crop.top - crop.bottom, cw = 1 - crop.left - crop.right;
  // Scale the frame so its content fits the picture rectangle (all of it stays visible); any
  // space left over is covered by the blurred surround.
  const k = Math.min(1 / cw, 1 / ch);
  const canvasW = w * k, canvasH = h * k;
  const contentW = canvasW * cw, contentH = canvasH * ch;
  content = { x: x + (w - contentW) / 2, y: y + (h - contentH) / 2, width: contentW, height: contentH };
  Object.assign(document.getElementById('pictureClip').style, {
    left: `${content.x}px`, top: `${content.y}px`, width: `${content.width}px`, height: `${content.height}px`,
  });
  Object.assign(document.getElementById('outputCanvas').style, {
    left: `${-canvasW * crop.left}px`, top: `${-canvasH * crop.top}px`, width: `${canvasW}px`, height: `${canvasH}px`,
  });
  document.documentElement.style.setProperty('--picture-bottom', `${y + h}px`);
  window.duo.resize();
}

// Black border sizes from a 160x120 copy of the frame, twice a second. The smallest value per side
// over the last ~5 s is used, so a dark scene is not mistaken for border.
function measureBorder(frame) {
  if (!cropProbe) {
    const c = document.createElement('canvas');
    c.width = 160; c.height = 120;
    cropProbe = c.getContext('2d', { willReadFrequently: true });
  }
  cropProbe.drawImage(frame, 0, 0, 160, 120);
  const d = cropProbe.getImageData(0, 0, 160, 120).data;
  const lit = (x, y) => { const i = (y * 160 + x) * 4; return d[i] + d[i + 1] + d[i + 2] > 30; };
  const rowLit = (y) => { for (let x = 0; x < 160; x += 2) if (lit(x, y)) return true; return false; };
  const colLit = (x) => { for (let y = 0; y < 120; y += 2) if (lit(x, y)) return true; return false; };
  let t = 0, b = 0, l = 0, r = 0;
  while (t < 15 && !rowLit(t)) t++;
  if (t === 15) return; // (nearly) black frame: tells nothing
  while (b < 15 && !rowLit(119 - b)) b++;
  while (l < 20 && !colLit(l)) l++;
  while (r < 20 && !colLit(159 - r)) r++;
  cropHistory.push({ top: t, bottom: b, left: l, right: r });
  if (cropHistory.length > 10) cropHistory.shift();
  const min = (k) => Math.min(...cropHistory.map((m) => m[k]));
  // Half a probe pixel extra so no partly black row is left at the edge.
  const next = {
    top: min('top') ? (min('top') + 0.5) / 120 : 0, bottom: min('bottom') ? (min('bottom') + 0.5) / 120 : 0,
    left: min('left') ? (min('left') + 0.5) / 160 : 0, right: min('right') ? (min('right') + 0.5) / 160 : 0,
  };
  if (['top', 'bottom', 'left', 'right'].some((k) => Math.abs(next[k] - crop[k]) > 0.002)) {
    crop = next;
    layoutPicture();
  }
}

// The surround: every edge of the content continues outwards to the edge of the screen (a row or
// column just inside it, stretched; the corners from the corner pixels), drawn small and blurred
// by CSS, so the picture blends into a blurred extension of itself on all four sides. The canvas
// reaches BLEED CSS pixels past the page so the blur does not fade at the borders.
const SURROUND_SCALE = 0.25; // canvas pixels per CSS pixel
const BLEED = 48;
let surroundContext = null;

function drawSurround(frame) {
  if (++presentedFrames % 30 === 1) measureBorder(frame);
  const canvas = document.getElementById('ambientCanvas');
  const width = Math.ceil((window.innerWidth + 2 * BLEED) * SURROUND_SCALE);
  const height = Math.ceil((window.innerHeight + 2 * BLEED) * SURROUND_SCALE);
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
    surroundContext = null;
  }
  const ctx = surroundContext || (surroundContext = canvas.getContext('2d'));
  const rect = content || { x: 0, y: 0, width: window.innerWidth, height: window.innerHeight };
  const px = (rect.x + BLEED) * SURROUND_SCALE, py = (rect.y + BLEED) * SURROUND_SCALE;
  const pw = rect.width * SURROUND_SCALE, ph = rect.height * SURROUND_SCALE;
  const fw = frame.width, fh = frame.height;
  const sx = fw * crop.left, sy = fh * crop.top;
  const sw = fw * (1 - crop.left - crop.right), sh = fh * (1 - crop.top - crop.bottom);
  const left = sx + sw * 0.01, top = sy + sh * 0.01;
  const rightCol = sx + sw * 0.99 - 1, bottomRow = sy + sh * 0.99 - 1;
  const right = px + pw, bottom = py + ph;
  ctx.imageSmoothingEnabled = true;
  ctx.drawImage(frame, sx, sy, sw, sh, px, py, pw, ph);
  ctx.drawImage(frame, sx, top, sw, 1, px, 0, pw, py);                               // top
  ctx.drawImage(frame, sx, bottomRow, sw, 1, px, bottom, pw, height - bottom);      // bottom
  ctx.drawImage(frame, left, sy, 1, sh, 0, py, px, ph);                              // left
  ctx.drawImage(frame, rightCol, sy, 1, sh, right, py, width - right, ph);          // right
  ctx.drawImage(frame, left, top, 1, 1, 0, 0, px, py);                               // corners
  ctx.drawImage(frame, rightCol, top, 1, 1, right, 0, width - right, py);
  ctx.drawImage(frame, left, bottomRow, 1, 1, 0, bottom, px, height - bottom);
  ctx.drawImage(frame, rightCol, bottomRow, 1, 1, right, bottom, width - right, height - bottom);
}

function canvasSize() {
  const canvas = document.getElementById('outputCanvas');
  const dpr = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.round(canvas.clientWidth * dpr));
  const height = Math.max(1, Math.round(canvas.clientHeight * dpr));
  return { canvas, width, height };
}

window.duo = {
  setPad(buttons, lx, ly, rx, ry) {
    M?.duoSetPad(buttons >>> 0, lx, ly, rx, ry);
  },
  pause() { paused = true; syncCard(); M?.duoPause(); suspendAudio(); },
  resume() { paused = false; M?.duoResume(); resumeAudio(); },
  syncCard() { return syncCard(); },
  // The picture's rectangle (CSS pixels); the rest of the page shows the blurred surround.
  setPicture(x, y, width, height) {
    picture = { x, y, width, height };
    layoutPicture();
  },
  resize() {
    if (!M || !started) return;
    const { canvas, width, height } = canvasSize();
    if (canvas.width === width && canvas.height === height) return;
    post({ type: 'log', message: `resize ${canvas.width}x${canvas.height} -> ${width}x${height}` });
    M.duoSetPresentation(width, height);
  },
  setFrameLimit(enabled) { M?.duoSetFrameLimit(!!enabled); },
  // QA (debug builds only): touch the memory card from the core's side.
  debugCardWrite(path, text) {
    if (!config.debug || !M) return false;
    const full = `${MC}/${path}`;
    M.FS.mkdirTree(full.substring(0, full.lastIndexOf('/')));
    M.FS.writeFile(full, text);
    return true;
  },
  debugCardDelete(path) {
    if (!config.debug || !M) return false;
    const full = `${MC}/${path}`;
    M.FS.unlink(full);
    try { M.FS.rmdir(full.substring(0, full.lastIndexOf('/'))); } catch (e) {}
    return true;
  },
  debugCaptureAudio(seconds) {
    if (config.debug && audioNode) audioNode.port.postMessage({ capture: seconds });
  },
  debugCardList() {
    return config.debug && M ? [...scanCard(M).keys()] : [];
  },
};

async function boot() {
  const t0 = performance.now();
  M = await Play({
    locateFile: (p) => `${location.origin}/${p}`,
    mainScriptUrlOrBlob: `${location.origin}/Play.js`,
    print: (t) => {
      if (t.startsWith('Failed to start')) post({ type: 'error', message: `boot: ${t}` });
      else if (config.debug) post({ type: 'log', message: t });
    },
    printErr: (t) => post({ type: 'log', message: t }),
    onAbort: (what) => post({ type: 'error', message: `abort: ${what}` }),
  });
  M.duoOnVibration = (large, small) => post({ type: 'rumble', large, small });
  // Frames from the GS thread (CGSH_OpenGLJs::PresentBackbuffer) go to the picture canvas; a
  // small copy of each also feeds the surround (drawSurround).
  const pictureContext = document.getElementById('outputCanvas').getContext('bitmaprenderer');
  M.duoPresentFrame = (frame) => {
    drawSurround(frame);
    pictureContext.transferFromImageBitmap(frame);
  };

  M.FS.mkdirTree(MC);
  M.FS.mkdirTree(HOST);
  const card = await (await fetch('/card-manifest')).json();
  await writeTree(M, MC, card.map((path) => ({ path, url: `/card/${path.split('/').map(encodeURIComponent).join('/')}` })));
  cardSnapshot = scanCard(M);
  if (config.elf) {
    const host = await (await fetch('/host-manifest')).json();
    await writeTree(M, HOST, host.map((path) => ({ path, url: `/host/${path.split('/').map(encodeURIComponent).join('/')}` })));
  }

  const warmed = await M.duoWarmWorkers();
  post({ type: 'log', message: `workers warmed ${warmed.filter(Boolean).length}/${warmed.length}` });
  const { width, height } = canvasSize();
  post({ type: 'log', message: `init canvas ${width}x${height} dpr=${window.devicePixelRatio}` });
  M.duoInit(width, height, MC, HOST);
  // Play!'s axis bindings start at 0 (full up-left) and only change on an input event, so push
  // one off-centre state and then neutral to centre all four axes before the game reads the pad.
  M.duoSetPad(0, 0x80, 0x80, 0x80, 0x80);
  M.duoSetPad(0, 0x7F, 0x7F, 0x7F, 0x7F);
  started = true;
  await startAudio();
  if (config.elf) M.duoBootElf(`${HOST}/${config.elf}`);
  else M.duoBootDisc(`/${config.disc}`);
  post({ type: 'booted', ms: Math.round(performance.now() - t0), cardFiles: card.length });

  let sawFrame = false;
  setInterval(() => {
    const frames = M.duoGetFrames();
    M.duoClearStats();
    if (!sawFrame && frames > 0) { sawFrame = true; post({ type: 'firstFrame' }); }
    const ring = new Uint32Array(M.duoMemory().buffer, M.duoAudioRing(), 2);
    post({ type: 'stats', fps: frames, audioWritten: ring[0], audioBuffered: (ring[0] - ring[1]) >>> 0, audioState: audio ? audio.state : 'none', audioStats, audioRate: audio ? audio.sampleRate : 0, baseLatency: audio ? audio.baseLatency : 0 });
    if (!paused) resumeAudio();
  }, 1000);
  setInterval(syncCard, 1000);
  window.addEventListener('resize', () => window.duo.resize());
  document.addEventListener('visibilitychange', () => post({ type: 'log', message: `visibility ${document.visibilityState}` }));
}

boot().catch((e) => post({ type: 'error', message: `boot: ${e && e.stack || e}` }));
