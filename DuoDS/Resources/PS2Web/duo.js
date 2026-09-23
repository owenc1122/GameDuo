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

// Plays the core's audio ring (SH_Duo) through an AudioWorklet at the SPU's 44.1 kHz.
async function startAudio() {
  try {
    audio = new AudioContext({ sampleRate: 44100, latencyHint: 'interactive' });
    await audio.audioWorklet.addModule('duo_audio.js');
    const node = new AudioWorkletNode(audio, 'duo-ps2-audio', { numberOfInputs: 0, outputChannelCount: [2] });
    node.port.postMessage({ memory: M.duoMemory(), ring: M.duoAudioRing(), samplesOffset: M.duoAudioRingSamplesOffset() });
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

  M.FS.mkdirTree(MC);
  M.FS.mkdirTree(HOST);
  const card = await (await fetch('/card-manifest')).json();
  await writeTree(M, MC, card.map((path) => ({ path, url: `/card/${path.split('/').map(encodeURIComponent).join('/')}` })));
  cardSnapshot = scanCard(M);
  if (config.elf) {
    const host = await (await fetch('/host-manifest')).json();
    await writeTree(M, HOST, host.map((path) => ({ path, url: `/host/${path.split('/').map(encodeURIComponent).join('/')}` })));
  }

  const { width, height } = canvasSize();
  post({ type: 'log', message: `init canvas ${width}x${height} dpr=${window.devicePixelRatio}` });
  M.duoInit(width, height, MC, HOST);
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
    post({ type: 'stats', fps: frames, audioWritten: ring[0], audioBuffered: (ring[0] - ring[1]) >>> 0, audioState: audio ? audio.state : 'none' });
    if (!paused) resumeAudio();
  }, 1000);
  setInterval(syncCard, 1000);
  window.addEventListener('resize', () => window.duo.resize());
  document.addEventListener('visibilitychange', () => post({ type: 'log', message: `visibility ${document.visibilityState}` }));
}

boot().catch((e) => post({ type: 'error', message: `boot: ${e && e.stack || e}` }));
