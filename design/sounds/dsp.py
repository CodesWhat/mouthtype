"""Tiny DSP toolkit for the Mouthtype cue designs. Standard library only."""
import math, struct, wave

FS = 48000
TWO_PI = 2.0 * math.pi


def n_of(sec):
    return int(round(sec * FS))


_SEMI = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}


def hz(name):
    """'G6' -> 1567.98 Hz (A4 = 440)."""
    pit, octv = name[:-1], int(name[-1])
    midi = 12 * (octv + 1) + _SEMI[pit]
    return 440.0 * 2.0 ** ((midi - 69) / 12.0)


# ---------------------------------------------------------------- buffers
def mix_into(dst, src, at=0.0, gain=1.0):
    o = n_of(at)
    need = o + len(src)
    if need > len(dst):
        dst.extend([0.0] * (need - len(dst)))
    for i, v in enumerate(src):
        dst[o + i] += v * gain
    return dst


def fade(x, atk=0.003, rel=0.005):
    """Raised-cosine in/out. First and last sample end up exactly 0."""
    na = max(2, n_of(atk))
    nr = max(2, n_of(rel))
    for i in range(min(na, len(x))):
        x[i] *= 0.5 - 0.5 * math.cos(math.pi * i / na)
    for i in range(min(nr, len(x))):
        x[-1 - i] *= 0.5 - 0.5 * math.cos(math.pi * i / nr)
    return x


def trim_tail(x, floor_db=-72.0, pad=0.004):
    """Cut trailing silence below floor_db re peak, keep a little pad."""
    pk = max(abs(v) for v in x) or 1.0
    thr = pk * 10 ** (floor_db / 20.0)
    last = 0
    for i in range(len(x) - 1, -1, -1):
        if abs(x[i]) > thr:
            last = i
            break
    return x[: min(len(x), last + 1 + n_of(pad))]


# ---------------------------------------------------------------- oscillators
def voice(dur, f, parts, atk=0.003, rel=0.005, glide=None, max_hz=13000.0):
    """Additive decaying partials. parts = [(ratio, amp, tau_seconds)].
    glide(t) -> frequency multiplier (optional)."""
    n = n_of(dur)
    out = [0.0] * n
    for ratio, amp, tau in parts:
        ph = 0.0
        inv = 1.0 / tau
        for i in range(n):
            t = i / FS
            ff = f * ratio * (glide(t) if glide else 1.0)
            if ff >= max_hz:
                break
            ph += TWO_PI * ff / FS
            out[i] += amp * math.sin(ph) * math.exp(-t * inv)
    return fade(out, atk, rel)


def fm_voice(dur, f, tau, idx, idx_tau, tine_idx=0.0, tine_tau=0.006, mod_ratio=1.0, atk=0.003, rel=0.005):
    """Two-operator-ish FM with a 14x 'tine' modulator for the tick."""
    n = n_of(dur)
    out = [0.0] * n
    w = TWO_PI * f / FS
    for i in range(n):
        t = i / FS
        i1 = idx * math.exp(-t / idx_tau)
        i2 = tine_idx * math.exp(-t / tine_tau)
        ph = w * i + i1 * math.sin(w * mod_ratio * i) + i2 * math.sin(w * 14.0 * i)
        out[i] = math.sin(ph) * math.exp(-t / tau)
    return fade(out, atk, rel)


def bl_square(dur, f, gate, max_hz=7500.0, rolloff=1.0, atk=0.003, rel=0.006, glide=None):
    """Band-limited square: odd harmonics below max_hz, amp 1/k^rolloff.
    gate(t) -> 0..1 amplitude envelope (applied before the edge fades)."""
    n = n_of(dur)
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / FS
        ff = f * (glide(t) if glide else 1.0)
        ph += TWO_PI * ff / FS
        s = 0.0
        k = 1
        while ff * k < max_hz:
            w = min(1.0, (max_hz - ff * k) / 1200.0)   # taper so harmonics never pop in or out
            s += w * math.sin(k * ph) / (k ** rolloff)
            k += 2
        out[i] = s * gate(t)
    return fade(out, atk, rel)


# ---------------------------------------------------------------- filters
def biquad(x, kind, f0, q=0.707):
    w0 = TWO_PI * f0 / FS
    cw, sw = math.cos(w0), math.sin(w0)
    al = sw / (2.0 * q)
    if kind == "lp":
        b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
    elif kind == "hp":
        b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
    elif kind == "bp":
        b0, b1, b2 = al, 0.0, -al
    else:
        raise ValueError(kind)
    a0, a1, a2 = 1 + al, -2 * cw, 1 - al
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    x1 = x2 = y1 = y2 = 0.0
    y = [0.0] * len(x)
    for i, v in enumerate(x):
        o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, v
        y2, y1 = y1, o
        y[i] = o
    return y


def svf_sweep(x, fc_of_t, q):
    """Chamberlin state-variable band-pass with a moving centre frequency."""
    low = band = 0.0
    inv_q = 1.0 / q
    out = [0.0] * len(x)
    for i, v in enumerate(x):
        fc = fc_of_t(i / FS)
        F = 2.0 * math.sin(math.pi * min(fc, 0.2 * FS) / FS)
        low += F * band
        high = v - low - inv_q * band
        band += F * high
        out[i] = band
    return out


def karplus(f, dur, tau_loop, excite, bright=0.5, atk=0.003, rel=0.005):
    """Karplus-Strong with 2-point averaging + first-order allpass tuning.
    excite: list of noise samples (>= delay length)."""
    n = n_of(dur)
    period = FS / f
    N = int(period - 1.0)
    d = period - 0.5 - N          # allpass delay target in [0.5, 1.5)
    c = (1.0 - d) / (1.0 + d)
    rho = math.exp(-1.0 / (f * tau_loop))
    # shape excitation: one-pole lowpass controls brightness
    buf = [0.0] * N
    lp = 0.0
    for i in range(N):
        lp += bright * (excite[i] - lp)
        buf[i] = lp
    m = sum(buf) / N
    buf = [v - m for v in buf]
    out = [0.0] * n
    idx = 0
    prev = 0.0
    ap_in = ap_out = 0.0
    for i in range(n):
        y = buf[idx]
        out[i] = y
        avg = 0.5 * (y + prev)
        prev = y
        ap = c * avg + ap_in - c * ap_out
        ap_in, ap_out = avg, ap
        buf[idx] = rho * ap
        idx += 1
        if idx == N:
            idx = 0
    return fade(out, atk, rel)


# ---------------------------------------------------------------- FFT / analysis
_TW = {}


def fft(re, im):
    n = len(re)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            re[i], re[j] = re[j], re[i]
            im[i], im[j] = im[j], im[i]
    if n not in _TW:
        _TW[n] = ([math.cos(TWO_PI * k / n) for k in range(n // 2)], [math.sin(TWO_PI * k / n) for k in range(n // 2)])
    cs, sn = _TW[n]
    length = 2
    while length <= n:
        half = length // 2
        step = n // length
        for i in range(0, n, length):
            k = 0
            for jj in range(i, i + half):
                wr, wi = cs[k], -sn[k]
                a, b = jj + half, jj
                xr = re[a] * wr - im[a] * wi
                xi = re[a] * wi + im[a] * wr
                re[a] = re[b] - xr
                im[a] = im[b] - xi
                re[b] += xr
                im[b] += xi
                k += step
        length <<= 1


def pow2_at_least(n, lo=16384):
    p = lo
    while p < n:
        p <<= 1
    return p


def power_spectrum(x, n_fft=None):
    n = n_fft or pow2_at_least(len(x))
    re = list(x) + [0.0] * (n - len(x))
    im = [0.0] * n
    fft(re, im)
    return [re[k] * re[k] + im[k] * im[k] for k in range(n // 2 + 1)], n


def a_weight_power(f):
    if f <= 0:
        return 0.0
    f2 = f * f
    ra = (12194.0 ** 2 * f2 * f2) / (
        (f2 + 20.6 ** 2) * math.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2)) * (f2 + 12194.0 ** 2)
    )
    db = 20 * math.log10(ra) + 2.0
    return 10 ** (db / 10.0)


def weighted_energy(P, n, weight=None):
    """Parseval: sum of squares of the time signal, optionally spectrum-weighted."""
    tot = 0.0
    last = len(P) - 1
    for k, p in enumerate(P):
        w = weight(k * FS / n) if weight else 1.0
        mult = 1.0 if k in (0, last) else 2.0
        tot += mult * p * w
    return tot / n


def la100_db(x):
    """A-weighted energy integrated over a 100 ms window, dB re full scale."""
    P, n = power_spectrum(x)
    e = weighted_energy(P, n, a_weight_power)
    return 10 * math.log10(max(e, 1e-20) / (0.1 * FS))


def kweight(x):
    """ITU-R BS.1770 K-weighting at 48 kHz."""
    stages = (
        ((1.53512485958697, -2.69169618940638, 1.19839281085285), (-1.69065929318241, 0.73248077421585)),
        ((1.0, -2.0, 1.0), (-1.99004745483398, 0.99007225036621)),
    )
    for (b0, b1, b2), (a1, a2) in stages:
        x1 = x2 = y1 = y2 = 0.0
        y = [0.0] * len(x)
        for i, v in enumerate(x):
            o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1 = x1, v
            y2, y1 = y1, o
            y[i] = o
        x = y
    return x


def lufs_momentary(x):
    """K-weighted energy over a 400 ms momentary window (cue sits inside it)."""
    y = kweight(x + [0.0] * 2400)
    e = sum(v * v for v in y)
    return -0.691 + 10 * math.log10(max(e, 1e-20) / (0.4 * FS))


def db(v):
    return 20 * math.log10(max(v, 1e-12))


# ---------------------------------------------------------------- WAV io
def write_wav(path, samples):
    ints = [max(-32768, min(32767, int(round(v * 32767.0)))) for v in samples]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(FS)
        w.writeframes(struct.pack("<%dh" % len(ints), *ints))


def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == FS, path
        raw = w.readframes(w.getnframes())
    ints = struct.unpack("<%dh" % (len(raw) // 2), raw)
    return [v / 32768.0 for v in ints], ints
