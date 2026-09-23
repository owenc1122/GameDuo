// AudioWorklet for the PS2 core: plays the SH_Duo ring buffer that the emulator writes into
// shared wasm memory. Runs on the audio rendering thread; never touches the main thread.
// Dynamic rate control: playback speed follows the buffer level (a few percent either way),
// so an emulator running slightly below or above real time never makes the sound break up.
const TARGET = 4096;       // frames (~93 ms) the ring is steered towards
const PRIME = 2048;        // frames needed to (re)start after running dry
const MAX_LATENCY = 16384; // frames (~370 ms); beyond this, skip ahead to TARGET
const MIN_STEP = 0.9, MAX_STEP = 1.06;

class DuoPS2Audio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ready = false;
    this.playing = false;
    this.step = 1;
    this.frac = 0;
    this.port.onmessage = (event) => {
      const { memory, ring, samplesOffset } = event.data;
      const buffer = memory.buffer;
      this.indices = new Uint32Array(buffer, ring, 4); // writeFrames, readFrames, capacity, sampleRate
      this.capacity = this.indices[2];
      this.samples = new Int16Array(buffer, ring + samplesOffset, this.capacity * 2);
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
    }
    if (!this.playing && available >= PRIME) this.playing = true;

    const desired = Math.min(MAX_STEP, Math.max(MIN_STEP, 1 + 0.08 * (available - TARGET) / TARGET));
    this.step += (desired - this.step) * 0.02;
    const needed = Math.ceil(this.frac + count * this.step) + 1;
    if (!this.playing || available < needed) {
      this.playing = false;
      left.fill(0); right.fill(0);
      Atomics.store(this.indices, 1, read);
      return true;
    }

    const capacity = this.capacity, samples = this.samples, step = this.step;
    let pos = this.frac;
    for (let i = 0; i < count; i++) {
      const whole = Math.floor(pos), t = pos - whole;
      const a = ((read + whole) >>> 0) % capacity, b = ((read + whole + 1) >>> 0) % capacity;
      left[i] = (samples[a * 2] * (1 - t) + samples[b * 2] * t) / 32768;
      right[i] = (samples[a * 2 + 1] * (1 - t) + samples[b * 2 + 1] * t) / 32768;
      pos += step;
    }
    const consumed = Math.floor(pos);
    this.frac = pos - consumed;
    Atomics.store(this.indices, 1, (read + consumed) >>> 0);
    return true;
  }
}

registerProcessor('duo-ps2-audio', DuoPS2Audio);
