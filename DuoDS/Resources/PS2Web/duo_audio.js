// AudioWorklet for the PS2 core: plays the SH_Duo ring buffer that the emulator writes into
// shared wasm memory. Runs on the audio rendering thread; never touches the main thread.
// Rate control: the emulator runs at full speed (frame skipping keeps it there), so only a tiny
// clock drift has to be absorbed. Playback speed may move at most 0.3% (about 5 cents, inaudible)
// and changes slowly, so the pitch never wobbles.
const TARGET = 6144;       // frames (128 ms at 48 kHz) the ring is steered towards
const PRIME = 1536;        // frames (32 ms) needed to (re)start after running dry
const FADE = 144;          // frames (3 ms) of fade at a dropout and when playback resumes
const LOW = TARGET / 3;    // below this, allow up to 1% slower playback so a hiccup does not
                           // run the buffer dry (a brief -17 cent dip beats a gap)
const MAX_LATENCY = 16384; // frames (~340 ms); beyond this, skip ahead to TARGET
const MIN_STEP = 0.997, MAX_STEP = 1.003;

class DuoPS2Audio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ready = false;
    this.playing = false;
    this.step = 1;
    this.frac = 0;
    this.fade = 0; // 0 -> 1 after (re)starting
    this.stats = { quanta: 0, underruns: 0, skips: 0, minAvailable: 1e9 };
    this.lastReport = currentTime;
    this.capture = null;
    this.port.onmessage = (event) => {
      if (event.data.capture) {
        this.capture = { data: new Float32Array(Math.round(event.data.capture * sampleRate) * 2), pos: 0 };
        return;
      }
      const { memory, ring, samplesOffset } = event.data;
      const buffer = memory.buffer;
      this.indices = new Uint32Array(buffer, ring, 4); // writeFrames, readFrames, capacity, sampleRate
      this.capacity = this.indices[2];
      this.samples = new Float32Array(buffer, ring + samplesOffset, this.capacity * 2); // 16-bit scale
      this.ready = true;
    };
  }

  process(inputs, outputs) {
    const out = outputs[0];
    const left = out[0], right = out[1] || out[0];
    const count = left.length;
    if (!this.ready) { left.fill(0); right.fill(0); return true; }

    const write = Atomics.load(this.indices, 0);
    let read = Atomics.load(this.indices, 1);
    let available = (write - read) >>> 0;
    if (available > MAX_LATENCY) {
      read = (write - TARGET) >>> 0;
      available = TARGET;
      this.frac = 0;
      this.stats.skips++;
    }
    this.stats.quanta++;
    if (this.playing) this.stats.minAvailable = Math.min(this.stats.minAvailable, available);
    if (currentTime - this.lastReport >= 1) {
      this.port.postMessage({ ...this.stats, step: this.step });
      this.stats = { quanta: 0, underruns: 0, skips: 0, minAvailable: 1e9 };
      this.lastReport = currentTime;
    }
    if (!this.playing && available >= PRIME) this.playing = true;

    if (available < LOW) {
      const desired = Math.max(0.99, 1 - 0.01 * (1 - available / LOW));
      this.step += (desired - this.step) * 0.02;
    } else {
      const desired = Math.min(MAX_STEP, Math.max(MIN_STEP, 1 + 0.003 * (available - TARGET) / TARGET));
      this.step += (desired - this.step) * 0.002;
    }
    if (!this.playing) {
      left.fill(0); right.fill(0);
      if (this.capture) this.record(left, right);
      return true;
    }

    // Render what is there; if the ring runs dry mid-quantum, fade the tail out and stop.
    const capacity = this.capacity, samples = this.samples, step = this.step;
    const usable = available - 1;
    let pos = this.frac, rendered = count;
    for (let i = 0; i < count; i++) {
      const whole = Math.floor(pos), t = pos - whole;
      if (whole >= usable) { rendered = i; break; }
      const a = ((read + whole) >>> 0) % capacity, b = ((read + whole + 1) >>> 0) % capacity;
      const gain = this.fade < 1 ? (this.fade = Math.min(1, this.fade + 1 / FADE)) : 1;
      left[i] = gain * (samples[a * 2] * (1 - t) + samples[b * 2] * t) / 32768;
      right[i] = gain * (samples[a * 2 + 1] * (1 - t) + samples[b * 2 + 1] * t) / 32768;
      pos += step;
    }
    if (rendered < count) {
      this.stats.underruns++;
      this.playing = false;
      this.fade = 0;
      const tail = Math.min(FADE, rendered);
      for (let i = 0; i < tail; i++) {
        const g = i / tail;
        left[rendered - tail + i] *= 1 - g;
        right[rendered - tail + i] *= 1 - g;
      }
      left.fill(0, rendered); right.fill(0, rendered);
    }
    if (this.capture) this.record(left, right);
    const consumed = Math.floor(pos);
    this.frac = pos - consumed;
    Atomics.store(this.indices, 1, (read + consumed) >>> 0);
    return true;
  }
}

DuoPS2Audio.prototype.record = function (left, right) {
  const c = this.capture;
  for (let i = 0; i < left.length && c.pos < c.data.length; i++) {
    c.data[c.pos++] = left[i];
    c.data[c.pos++] = right[i];
  }
  if (c.pos >= c.data.length) {
    this.port.postMessage({ captured: c.data }, [c.data.buffer]);
    this.capture = null;
  }
};

registerProcessor('duo-ps2-audio', DuoPS2Audio);
