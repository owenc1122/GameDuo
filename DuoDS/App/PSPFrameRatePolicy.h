#pragma once

// Conservative, per-launch qualification. Rates count game flips, not display
// refreshes. No patch, frame duplication, or emulation-speed change is applied.
struct PSPFrameRatePolicy {
    enum class State { observing, trial, enhanced, original };
    State state = State::observing;
    unsigned observed = 0, badWindows = 0, trialWindows = 0, slowWindows = 0;
    double baselineFPS = 0;

    void reset(bool high) { *this = {}; if (!high) state = State::original; }
    bool boosted() const { return state == State::trial || state == State::enhanced; }

    void sample(double gameFPS, double emulationHz, double workFraction,
                double missedFraction, bool hot, bool clockCompatible) {
        if (state == State::original) return;
        if (hot || !clockCompatible) { state = State::original; return; }
        const bool fullSpeed = emulationHz >= 58.0 && emulationHz <= 62.0;
        const bool headroom = fullSpeed && workFraction < 0.70 && missedFraction < 0.05;
        if (state == State::observing) {
            // Discard boot/loading windows; native 60 fps needs no extra work.
            if (++observed < 3 || gameFPS < 18 || gameFPS >= 57 || !headroom) {
                slowWindows = 0;
                return;
            }
            // A single loading/shader hitch must not permanently boost a
            // native-60 game. Require two consecutive, similar slow windows.
            if (!slowWindows || gameFPS < baselineFPS - 5 || gameFPS > baselineFPS + 5) {
                baselineFPS = gameFPS;
                slowWindows = 1;
                return;
            }
            ++slowWindows;
            baselineFPS = (baselineFPS + gameFPS) * 0.5;
            state = State::trial;
            return;
        }
        const bool qualified = gameFPS >= 57 && gameFPS <= 62 && fullSpeed && workFraction < 0.85 && missedFraction < 0.08;
        if (state == State::trial) {
            // Require two consecutive four-second windows near 60 fps.
            ++trialWindows;
            if (!qualified || gameFPS < baselineFPS + 3) { state = State::original; return; }
            if (trialWindows >= 2) state = State::enhanced;
        } else {
            badWindows = qualified ? 0 : badWindows + 1;
            // A scene change gets one grace window. Once reverted, don't keep
            // oscillating/probing in the same session.
            if (badWindows >= 2) state = State::original;
        }
    }
};
