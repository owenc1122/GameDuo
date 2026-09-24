# Play! (WebAssembly) for Game Duo

The PS2 core is [Play!](https://github.com/jpd002/Play-) by Jean-Philip Desjardins (BSD 2-clause,
see `LICENSE-Play.txt`), pinned to commit `83700b2c`, compiled to WebAssembly with emscripten
and run inside a WKWebView, whose WebKit JIT compiles Play!'s recompiled MIPS code.

`duo.patch` (apply to the pinned commit; `build.sh` does everything) changes:

- `Source/ui_js/Main.cpp`: Game Duo entry points (`duoInit`, `duoBootDisc`, `duoBootElf`,
  `duoSetPad`, `duoPause`/`duoResume` (asynchronous), `duoSetPresentation`, frame stats, audio
  ring address); the page canvas shows ImageBitmaps from the GS thread (`bitmaprenderer`).
- `Source/ui_js/GSH_OpenGLJs.*`, `duo_pre.js`: the GS thread renders on its own OffscreenCanvas
  (WebGL2 in its worker, no GL proxying to the main thread) and posts each finished frame. WebKit
  creates worker contexts through the main run loop, so every pthread worker makes its canvas and
  context before `duoInit` blocks the main thread (`duoWarmWorkers`).
- `Source/gs/GSH_OpenGL/GSH_OpenGL.*`: adaptive frame skipping. Below ~55 fps, only every other
  frame is drawn so emulation and sound stay at full speed; drawing every frame is retried with
  growing back-off (3 s up to 30 s). `GSH_OpenGL/CMakeLists.txt`: WebAssembly SIMD for this
  library only (texture swizzling via the NEON path).
- `Source/gs/GSHandler.cpp`, `GsPixelFormats.h`: host-to-local transfers written in row runs,
  one page segment at a time (was per-pixel addressing).
- `Source/FrameLimiter.*`: deadline pacing on emscripten (sleep overshoot no longer accumulates).
- `Source/ui_js/InputProviderDuo.*`: whole-pad state from the app, motors reported back.
- `Source/ui_js/SH_Duo.*`: SPU output into a lock-free ring buffer in wasm memory, played by an
  AudioWorklet (`DuoDS/Resources/PS2Web/duo_audio.js`) with dynamic rate control.
- `Source/Js_DiscImageDeviceStream.*`, `Source/DiskUtils.cpp`, `Source/ui_js/duo_pre.js`:
  path-aware, synchronous (worker-side) disc reads with a block cache; BIN/CUE tracks load by name.
- `Source/iop/IopBios.cpp`: pad drivers loaded from EE memory (ps2sdk freepad/freesio2) use the
  HLE pad manager.
- `Source/iop/Iop_PadMan.*`: libpad protocol completed (mode/actuator info, button mask, port and
  slot counts, actuator direct → rumble), DualShock 2 mode table in the new-style pad buffer;
  button pressure bytes follow the buttons (they stayed 0xFF, i.e. every button fully pressed).
- `Source/ISO9660/*`, `Source/iop/ioman/OpticalMediaDirectoryIterator.*`: directories longer than
  one sector are read completely (sector padding is not the end); exact file name matching.
- `Source/ui_js/Ps2VmJs.*`: asynchronous resume / frame-limit reload.
- `Source/ui_js/InputProviderDuo.*`: the first pad state reports every axis (bindings start at 0).
- `Source/ui_js/CMakeLists.txt`: new sources, `--pre-js duo_pre.js`, pthread pool of 6,
  OffscreenCanvas support, native wasm exceptions, mimalloc. `build.sh` also switches the
  Dependencies submodule's `-fexceptions` to `-fwasm-exceptions` (not covered by the patch).

Regenerate the patch with `git diff --ignore-submodules > duo.patch` (after `git add -N` for new files).

Build: `ThirdParty/PlayWeb/build.sh` (needs Python ≥ 3.10 for emsdk: set `EMSDK_PYTHON`).
Outputs `Play.js` and `Play.wasm` into `DuoDS/Resources/PS2Web/`.
