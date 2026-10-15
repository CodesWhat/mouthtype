"""Regenerates every cue WAV deterministically: python3 -I build.py"""
import math, os, random, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dsp import *  # noqa: E402,F401,F403

HERE = os.path.dirname(os.path.abspath(__file__))
WAV_DIR = os.path.join(HERE, "wav")
CUES = ["start", "stop", "lock", "error", "cancel", "pasted"]

# ---- loudness policy -------------------------------------------------------
# Every cue is scaled so its A-weighted energy over a 100 ms window (LA100)
# lands on TARGET_LA + role offset. Peak is capped at PEAK_CEIL.
TARGET_LA = -25.5
ROLE_OFFSET = {"start": 0.0, "stop": 0.0, "lock": 0.0, "error": -1.0, "cancel": -3.0, "pasted": -5.0}
PEAK_CEIL_DB = -6.2


def seq(*items):
    out = []
    for at, buf, gain in items:
        mix_into(out, buf, at, gain)
    return out


def noise(n, seed):
    r = random.Random(seed)
    return [r.uniform(-1.0, 1.0) for _ in range(n)]


def expenv(x, tau):
    return [v * math.exp(-i / (FS * tau)) for i, v in enumerate(x)]


# =============================================================== 1. SOFT
def _soft(f, tau, dur=None):
    return voice(dur or 7.5 * tau, f, [(1, 1.0, tau), (2, 0.16, tau * 0.6), (3, 0.05, tau * 0.4)], atk=0.003, rel=0.004)


def set_soft():
    G6, C7, E7 = hz("G6"), hz("C7"), hz("E7")
    return {
        "start": seq((0.0, _soft(G6, 0.008), 0.8), (0.032, _soft(C7, 0.009), 1.0)),
        "stop": seq((0.0, _soft(C7, 0.012), 0.8), (0.045, _soft(G6, 0.018), 1.0)),
        "lock": seq((0.0, _soft(G6, 0.008), 0.7), (0.032, _soft(C7, 0.009), 0.85), (0.064, _soft(E7, 0.030), 1.0)),
        "error": seq(
            (0.0, voice(0.19, hz("G4"), [(1, 1.0, 0.025), (3, 0.12, 0.015)], atk=0.005, rel=0.008), 1.0),
            (0.10, voice(0.22, hz("E4"), [(1, 1.0, 0.030), (3, 0.12, 0.018)], atk=0.005, rel=0.008), 1.0),
        ),
        "cancel": voice(0.2, hz("C7"), [(1, 1.0, 0.03), (2, 0.12, 0.02)], glide=lambda t: 2.0 ** (-min(t / 0.075, 1.0) * 1.1)),
        "pasted": _soft(hz("E7"), 0.012),
    }


# =============================================================== 2. GLASS
_GLASS = [(1.0, 1.0, 1.0), (2.32, 0.45, 0.5), (4.25, 0.22, 0.3), (6.63, 0.09, 0.15)]


def _glass(f, tau, dur=None, seed=1):
    parts = [(r, a, tau * ts) for r, a, ts in _GLASS if f * r < 12000]
    v = voice(dur or 7.5 * tau, f, parts, atk=0.0025, rel=0.004)
    # 2.5 ms glassy tick on the strike
    tick = biquad(noise(n_of(0.012), seed), "bp", 6500, 2.0)
    tick = fade(expenv(tick, 0.0015), 0.0015, 0.004)
    for i, s in enumerate(tick):
        v[i] += 0.10 * s
    return v


def set_glass():
    A6, E7, A7 = hz("A6"), hz("E7"), hz("A7")
    return {
        "start": seq((0.0, _glass(A6, 0.008, seed=11), 0.75), (0.030, _glass(E7, 0.009, seed=12), 1.0)),
        "stop": seq((0.0, _glass(E7, 0.014, seed=13), 0.7), (0.042, _glass(A6, 0.032, seed=14), 1.0)),
        "lock": seq((0.0, _glass(A6, 0.008, seed=15), 0.6), (0.030, _glass(E7, 0.009, seed=16), 0.8), (0.060, _glass(A7, 0.026, seed=17), 0.9)),
        "error": seq((0.0, _glass(hz("C5"), 0.025, 0.19, seed=18), 1.0), (0.10, _glass(hz("A4"), 0.030, 0.22, seed=19), 1.0)),
        "cancel": seq((0.0, _glass(hz("E7"), 0.008, seed=20), 0.8), (0.028, _glass(hz("D7"), 0.014, seed=21), 0.9)),
        "pasted": _glass(hz("A7"), 0.011, seed=22),
    }


# =============================================================== 3. WOOD
def _bar(f, tau, dur=None, seed=1):
    v = voice(dur or 7.5 * tau, f, [(1, 1.0, tau), (3.98, 0.50, tau * 0.45), (10.1, 0.15, tau * 0.2)], atk=0.0025, rel=0.004)
    knock = biquad(noise(n_of(0.015), seed), "bp", 1800, 1.4)
    knock = fade(expenv(knock, 0.002), 0.002, 0.005)
    for i, s in enumerate(knock):
        v[i] += 0.28 * s
    return v


def set_wood():
    F5, C6, F6 = hz("C6"), hz("G6"), hz("C7")
    return {
        "start": seq((0.0, _bar(F5, 0.009, seed=31), 0.8), (0.032, _bar(C6, 0.009, seed=32), 1.0)),
        "stop": seq((0.0, _bar(C6, 0.016, seed=33), 0.7), (0.045, _bar(F5, 0.026, seed=34), 1.0)),
        "lock": seq((0.0, _bar(F5, 0.009, seed=35), 0.6), (0.032, _bar(C6, 0.009, seed=36), 0.8), (0.064, _bar(F6, 0.022, seed=37), 1.0)),
        "error": seq((0.0, _bar(hz("F4"), 0.025, 0.19, seed=38), 1.0), (0.10, _bar(hz("D4"), 0.030, 0.22, seed=39), 1.0)),
        "cancel": seq((0.0, _bar(hz("A5"), 0.008, seed=40), 0.8), (0.026, _bar(hz("F5"), 0.014, seed=41), 0.9)),
        "pasted": _bar(hz("C7"), 0.010, seed=42),
    }


# =============================================================== 4. CLICK
def _click(noise_f, noise_q, noise_tau, pop_f0, pop_f1, pop_glide, pop_tau, noise_amp, pop_amp, dur, seed, pop_h2=0.0, atk=0.002):
    n = n_of(dur)
    nz = biquad(noise(n, seed), "bp", noise_f, noise_q)
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / FS
        f = pop_f1 + (pop_f0 - pop_f1) * math.exp(-t / pop_glide)
        ph += TWO_PI * f / FS
        e = math.exp(-t / pop_tau)
        out[i] = noise_amp * nz[i] * math.exp(-t / noise_tau) + pop_amp * e * (math.sin(ph) + pop_h2 * math.sin(2 * ph))
    return fade(out, atk, 0.004)


def set_click():
    return {
        # key down: bright, pop rises
        "start": _click(3800, 1.2, 0.004, 430, 620, 0.006, 0.010, 1.0, 0.45, 0.085, 51),
        # key up: duller, softer, pop falls
        "stop": _click(2400, 1.0, 0.005, 560, 300, 0.010, 0.013, 0.8, 0.5, 0.10, 52),
        "lock": seq((0.0, _click(3800, 1.2, 0.004, 430, 620, 0.006, 0.008, 1.0, 0.45, 0.07, 53), 0.9),
                    (0.058, _click(4600, 1.2, 0.004, 640, 820, 0.006, 0.009, 1.0, 0.45, 0.09, 54), 1.0)),
        "error": seq((0.0, _click(900, 1.0, 0.012, 190, 150, 0.02, 0.026, 0.25, 1.0, 0.20, 55, pop_h2=0.55), 1.0),
                     (0.100, _click(800, 1.0, 0.012, 150, 120, 0.02, 0.030, 0.25, 1.0, 0.24, 56, pop_h2=0.55), 1.0)),
        "cancel": _click(1800, 1.0, 0.005, 620, 240, 0.014, 0.014, 0.7, 0.8, 0.10, 57),
        "pasted": _click(5200, 1.5, 0.003, 900, 800, 0.004, 0.005, 1.0, 0.35, 0.04, 58, atk=0.003),
    }


# =============================================================== 5. PAGER
def _beep(f, dur, hold, rel_tau, max_hz=7500.0, rolloff=1.0, glide=None):
    """Square beep: flat for `hold` seconds, then exponential release."""
    def gate(t):
        return 1.0 if t < hold else math.exp(-(t - hold) / rel_tau)
    return bl_square(dur, f, gate, max_hz=max_hz, rolloff=rolloff, atk=0.003, rel=0.004, glide=glide)


def set_pager():
    G6, D7, G7 = hz("G6"), hz("D7"), hz("G7")
    return {
        "start": seq((0.0, _beep(G6, 0.045, 0.026, 0.005), 0.8), (0.030, _beep(D7, 0.060, 0.024, 0.006), 1.0)),
        "stop": _beep(hz("C6"), 0.18, 0.060, 0.016),
        "lock": seq((0.0, _beep(G6, 0.045, 0.026, 0.005), 0.7), (0.030, _beep(D7, 0.045, 0.026, 0.005), 0.85), (0.060, _beep(G7, 0.140, 0.060, 0.016), 1.0)),
        "error": seq((0.0, _beep(hz("G4"), 0.13, 0.060, 0.012, max_hz=2600, rolloff=1.5), 1.0),
                     (0.105, _beep(hz("E4"), 0.17, 0.070, 0.016, max_hz=2600, rolloff=1.5), 1.0)),
        "cancel": _beep(1800, 0.12, 0.050, 0.012, glide=lambda t: math.exp(-min(t / 0.06, 1.0) * math.log(3.0))),
        "pasted": _beep(D7, 0.040, 0.016, 0.005),
    }


# =============================================================== 6. BREATH
def _puff(dur, f0, f1, sweep, q, peak_t, tau, seed):
    n = n_of(dur)
    nz = noise(n, seed)
    lf0, lf1 = math.log(f0), math.log(f1)
    band = svf_sweep(nz, lambda t: math.exp(lf0 + (lf1 - lf0) * min(t / sweep, 1.0)), q)
    out = [0.0] * n
    for i, v in enumerate(band):
        t = i / FS
        env = 0.5 - 0.5 * math.cos(math.pi * t / peak_t) if t < peak_t else math.exp(-(t - peak_t) / tau)
        out[i] = v * env
    return fade(out, 0.003, 0.004)


def set_breath():
    return {
        "start": _puff(0.12, 2300, 5600, 0.060, 5.0, 0.016, 0.010, 61),                       # inhale: rising, quick
        "stop": _puff(0.30, 5200, 1900, 0.150, 4.0, 0.030, 0.026, 62),                         # exhale: falling, softer
        "lock": seq((0.0, _puff(0.12, 2300, 5600, 0.060, 5.0, 0.016, 0.010, 63), 0.8),
                    (0.050, _puff(0.20, 3600, 7600, 0.080, 5.0, 0.020, 0.022, 64), 1.0)),
        "error": seq((0.0, _puff(0.17, 520, 400, 0.10, 9.0, 0.020, 0.025, 65), 1.0),
                     (0.100, _puff(0.20, 430, 330, 0.10, 9.0, 0.020, 0.030, 66), 1.0)),
        "cancel": _puff(0.14, 4500, 1500, 0.05, 4.0, 0.010, 0.016, 67),
        "pasted": _puff(0.06, 7200, 7200, 0.01, 3.0, 0.008, 0.008, 68),
    }


# =============================================================== 7. PLUCK (Karplus-Strong)
def _pluck(f, tau_loop, tau_env, dur, seed, bright=0.6):
    ex = noise(int(FS / f) + 4, seed)
    v = karplus(f, dur, tau_loop, ex, bright=bright)
    return fade(expenv(v, tau_env), 0.002, 0.004)


def set_pluck():
    D6, A6, D7 = hz("D6"), hz("A6"), hz("D7")
    return {
        "start": seq((0.0, _pluck(D6, 0.020, 0.010, 0.09, 71), 0.8), (0.030, _pluck(A6, 0.020, 0.010, 0.09, 72), 1.0)),
        "stop": seq((0.0, _pluck(A6, 0.030, 0.016, 0.16, 73), 0.7), (0.045, _pluck(D6, 0.060, 0.030, 0.26, 74), 1.0)),
        "lock": seq((0.0, _pluck(D6, 0.020, 0.010, 0.09, 75), 0.6), (0.030, _pluck(A6, 0.020, 0.010, 0.09, 76), 0.8), (0.060, _pluck(D7, 0.050, 0.026, 0.22, 77), 1.0)),
        "error": seq((0.0, _pluck(hz("C4"), 0.07, 0.030, 0.20, 78, 0.5), 1.0), (0.10, _pluck(hz("A3"), 0.08, 0.035, 0.24, 79, 0.5), 1.0)),
        "cancel": seq((0.0, _pluck(hz("F6"), 0.020, 0.009, 0.09, 80), 0.8), (0.028, _pluck(hz("C6"), 0.025, 0.014, 0.12, 81), 0.9)),
        "pasted": _pluck(D7, 0.020, 0.010, 0.09, 82),
    }


# =============================================================== 8. KEYS (FM electric piano)
def _ep(f, tau, dur=None, idx=1.3):
    return fm_voice(dur or 7.5 * tau, f, tau, idx, 0.014, tine_idx=0.35, tine_tau=0.005)


def set_keys():
    E6, Cs7, E7 = hz("E6"), hz("C#7"), hz("E7")
    return {
        "start": seq((0.0, _ep(E6, 0.008), 0.8), (0.030, _ep(Cs7, 0.009), 1.0)),
        "stop": seq((0.0, _ep(Cs7, 0.012), 0.7), (0.044, _ep(E6, 0.026), 1.0)),
        "lock": seq((0.0, _ep(E6, 0.008), 0.6), (0.030, _ep(Cs7, 0.009), 0.8), (0.060, _ep(E7, 0.026), 1.0)),
        "error": seq((0.0, _ep(hz("A3"), 0.025, 0.19, idx=1.6), 1.0), (0.10, _ep(hz("F#3"), 0.030, 0.22, idx=1.6), 1.0)),
        "cancel": seq((0.0, _ep(hz("G#6"), 0.008), 0.8), (0.028, _ep(hz("E6"), 0.014), 0.9)),
        "pasted": _ep(hz("B6"), 0.010),
    }


SETS = {
    "soft": ("Soft", "Two warm sine blips. Rising fourth to start, same fourth falling to stop.", set_soft),
    "glass": ("Glass", "Short glass ticks from inharmonic partials. Rising fifth to start, falling to stop.", set_glass),
    "wood": ("Wood", "Marimba bar strikes, a little lower and drier. Rising fifth, falling fifth.", set_wood),
    "click": ("Click", "Most minimal: soft keypress thunk. Bright key-down to start, duller key-up to stop.", set_click),
    "pager": ("Pager", "Gadget skin: band-limited square beeps. Two-note chirp up to start, one lower beep to stop.", set_pager),
    "breath": ("Breath", "Filtered-noise inhale (rising) to start, longer exhale (falling) to stop.", set_breath),
    "pluck": ("Pluck", "Karplus-Strong plucked string pair, harp-like. Rising fifth, falling fifth.", set_pluck),
    "keys": ("Keys", "FM electric-piano ticks. Rising major sixth to start, falling to stop.", set_keys),
}


def render_all(verbose=True):
    """-> {set: {cue: [float samples, scaled]}}"""
    result = {}
    for sid, (_, _, fn) in SETS.items():
        raw = fn()
        scaled = {}
        for cue in CUES:
            x = fade(trim_tail(raw[cue]), 0.0, 0.003)  # guarantee a zero final sample
            # remove any residual DC, then re-apply the edge fades
            for _ in range(4):
                m = sum(x) / len(x)
                x = fade([v - m for v in x], 0.002, 0.003)
            target = TARGET_LA + ROLE_OFFSET[cue]
            g = 10 ** ((target - la100_db(x)) / 20.0)
            peak = max(abs(v) for v in x) * g
            ceil = 10 ** (PEAK_CEIL_DB / 20.0)
            if peak > ceil:
                if verbose:
                    print("  peak-limited: %s/%s by %.1f dB" % (sid, cue, db(peak / ceil)))
                g *= ceil / peak
            scaled[cue] = [v * g for v in x]
        result[sid] = scaled
    return result


def main():
    allc = render_all()
    for sid, cues in allc.items():
        d = os.path.join(WAV_DIR, sid)
        os.makedirs(d, exist_ok=True)
        for cue, x in cues.items():
            write_wav(os.path.join(d, cue + ".wav"), x)
        print("wrote", sid)


if __name__ == "__main__":
    main()
