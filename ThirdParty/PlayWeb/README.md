# Play! (WebAssembly) for Game Duo

The PS2 core is [Play!](https://github.com/jpd002/Play-) by Jean-Philip Desjardins (BSD 2-clause,
see `LICENSE-Play.txt`), pinned to commit `83700b2c`, compiled to WebAssembly with emscripten
and run inside a WKWebView, whose WebKit JIT compiles Play!'s recompiled MIPS code.

`duo.patch` (apply to the pinned commit; `build.sh` does everything) changes:

- `Source/ui_js/Main.cpp`: Game Duo entry points (`duoInit`, `duoBootDisc`, `duoBootElf`,
  `duoSetPad`, `duoPause`/`duoResume` (asynchronous), `duoSetPresentation`, frame stats, audio
  ring address); explicit WebGL swap control so only finished frames reach the canvas.
- `Source/ui_js/InputProviderDuo.*`: whole-pad state from the app, motors reported back.
- `Source/ui_js/SH_Duo.*`: SPU output into a lock-free ring buffer in wasm memory, played by an
  AudioWorklet (`DuoDS/Resources/PS2Web/duo_audio.js`) with dynamic rate control.
- `Source/Js_DiscImageDeviceStream.*`, `Source/DiskUtils.cpp`, `Source/ui_js/duo_pre.js`:
  path-aware, synchronous (worker-side) disc reads with a block cache; BIN/CUE tracks load by name.
- `Source/iop/IopBios.cpp`: pad drivers loaded from EE memory (ps2sdk freepad/freesio2) use the
  HLE pad manager.
- `Source/iop/Iop_PadMan.*`: libpad protocol completed (mode/actuator info, button mask, port and
  slot counts, actuator direct → rumble), DualShock 2 mode table in the new-style pad buffer.
- `Source/ui_js/Ps2VmJs.*`: asynchronous resume / frame-limit reload.
- `Source/ui_js/CMakeLists.txt`: new sources, `--pre-js duo_pre.js`, pthread pool of 6.

Build: `ThirdParty/PlayWeb/build.sh` (needs Python ≥ 3.10 for emsdk: set `EMSDK_PYTHON`).
Outputs `Play.js` and `Play.wasm` into `DuoDS/Resources/PS2Web/`.
