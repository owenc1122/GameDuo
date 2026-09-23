# Cartridge insertion sound

- File: `Cartridge-Finger-Snap.wav`
- User-provided source: `RPReplay_Final1789938901.mov`
- Source SHA-256: `e52406d1b5cb9ae8de2d0311799c3cf71a84b404869d506baba95a3654ef293f`
- App asset SHA-256: `a9db96b354701a41b0bee89ab76575303d71797e263ed66d762eac49be564436`
- Processing: extracted 1.400–2.300 seconds from the user-provided recording. A soft spectral noise reduction profile is derived only from the 160 ms lead-in before the impact; a Wiener-style mask with a conservative floor removes steady background noise while preserving the transient and natural decay. The mono 44.1 kHz PCM asset is then raised by two semitones, limited to 65% peak level, and given 2 ms/15 ms boundary fades. No synthesized layers were added.

# PS2 界面音效（`PS2Audio/`）

全部为 Freesound CC0（Creative Commons 0，公有领域），可商用、无需署名；用户已试听确认（2026-09-23）。素材取自 Freesound 128 kbps 高质量预览，裁剪到指定时间段、去掉首尾静音、峰值归一化到 −3 dBFS，转为 44.1 kHz 16-bit 单声道 PCM。

| 文件 | 来源 | 作者 | 截取 | SHA-256 |
|---|---|---|---|---|
| `PS2-Case-Open.wav` | https://freesound.org/people/ewellis/sounds/792907/ （真实 PS2 游戏盒） | ewellis | 0.93–1.40 s | `95d0ef6c014568de5773f372939045fcde35293d9216c6e5fe21c72791a20334` |
| `PS2-Case-Close.wav` | https://freesound.org/people/ewellis/sounds/792907/ | ewellis | 2.82–3.10 s | `f9fd133b12de6ab4244c36c4e8df4e695e40ebe69001fd0dca393c34a7128785` |
| `PS2-MemoryCard-Insert.wav` | https://freesound.org/people/KieranKeegan/sounds/418230/ （通用塑料插卡，无 PS2 记忆卡实录） | KieranKeegan | 0.31–0.72 s | `e132865c430051e13a96f0120e9a98b143b7221b8116d51637c11c789a7a77b0` |
| `PS2-Tray-Eject.wav` | https://freesound.org/people/thaighaudio/sounds/351377/ （Sony DVP-S530D DVD 机） | thaighaudio | 5.00–6.52 s | `af95632e4b1495e7e45866016718003005057e7189af03369c19ab699f7e4b73` |
| `PS2-Tray-Retract.wav` | https://freesound.org/people/thaighaudio/sounds/351377/ | thaighaudio | 7.00–8.62 s | `6e527de1a77bbb965b4c50abc3c5da841fb49f401993792e4dcd5be0f577fa16` |

光盘卡上托盘沿用上方的 `Cartridge-Finger-Snap.wav`。
