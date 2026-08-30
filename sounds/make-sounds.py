#!/usr/bin/env python3
"""Generate pager's notification sounds.

    python3 sounds/make-sounds.py

Ten sounds, ten different ways of making a sound. That is the point. A single
synth model with eleven parameter sets gives you eleven cousins, which is the
trap the first attempt at this fell into. Here each one is built from a
different mechanism, so they are told apart instantly even at low volume on a
laptop speaker:

    chirp   two swept tones          ported from make-toast-sound "flat, tight"
    tick    filtered noise           no pitch at all
    drop    exponential pitch rise   a droplet
    wood    inharmonic struck bar    fast attack, no sustain
    bell    FM with decaying index   metallic, long
    glass   additive inharmonics     beating partials, shimmer tail
    rise    three ascending tones    melodic
    fall    two descending tones     melodic, the inverse
    thump   sub sine with pitch drop felt more than heard
    alarm   gated harmonic pulses    insistent, three hits

Only stdlib, so this stays runnable anywhere without a wheel to install.
"""

import math
import random
import struct
import wave
from pathlib import Path

RATE = 48000
HERE = Path(__file__).parent


# ---------------------------------------------------------------- helpers

def silence(seconds):
    return [0.0] * int(RATE * seconds)


def lowpass(signal, cutoff):
    """One pole. Enough to take the fizz off noise without a filter library."""
    a = 1 - math.exp(-2 * math.pi * cutoff / RATE)
    out, last = [], 0.0
    for sample in signal:
        last += a * (sample - last)
        out.append(last)
    return out


def highpass(signal, cutoff):
    return [s - l for s, l in zip(signal, lowpass(signal, cutoff))]


def normalise(signal, peak=0.78, trim=1.0):
    """Peak normalise, then a per sound trim because equal peaks are not equal
    loudness. A bright bell at 0.78 is far louder to the ear than a sub thump
    at 0.78."""
    high = max((abs(s) for s in signal), default=0.0) or 1.0
    return [s / high * peak * trim for s in signal]


def fade_out(signal, seconds=0.012):
    """Anything that ends on a non-zero sample clicks. Cheaper to always fade."""
    count = min(int(RATE * seconds), len(signal))
    for i in range(count):
        signal[len(signal) - count + i] *= 1 - i / count
    return signal


def write(name, signal, trim=1.0):
    signal = fade_out(normalise(list(signal), trim=trim))
    path = HERE / f"{name}.wav"
    with wave.open(str(path), "w") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in signal
        ))
    peak = max((abs(s) for s in signal), default=0)
    rms = math.sqrt(sum(s * s for s in signal) / len(signal))
    print(f"  {name:<7} {len(signal) / RATE:5.2f}s  peak {peak:4.2f}  rms {rms:5.3f}")


# ---------------------------------------------------------------- the sounds

def chirp():
    """Ported line for line from make-toast-sound at its "flat, tight" preset:
    sweep 1.0, everything else default. The one Adam kept."""
    base, interval, gap = 880, 1.122, 0.230
    sweep, glide, decay = 1.0, 0.130, 26
    body, shimmer, second = 0.30, 0.22, 0.78

    def voice(t, root, gain):
        if t < 0 or t > 1.0:
            return 0.0
        k = (root * (sweep - 1)) / glide
        swept = min(t, glide)
        phase = 2 * math.pi * (root * t + 0.5 * k * swept * swept)
        tone = (math.sin(phase)
                + shimmer * math.sin(2 * phase)
                + shimmer * 0.3 * math.sin(3 * phase))
        return tone * min(1, t / 0.006) * math.exp(-t * decay) * gain

    voices = [(0, base, 1.0), (gap, base * interval, second)]
    out = []
    for i in range(int(RATE * (gap + 0.55))):
        t = i / RATE
        s = sum(voice(t - start, root, gain) for start, root, gain in voices)
        for start, _, gain in voices:
            dt = t - start
            if 0 <= dt < 0.5:
                s += body * gain * math.sin(2 * math.pi * 146.8 * dt) * math.exp(-dt * 9)
        out.append(math.tanh(s * 0.9) * 0.8)
    return out


def tick():
    """Filtered noise. No pitch, so it cannot be confused with anything else
    here. This is the one for something small and constant."""
    random.seed(7)
    length = int(RATE * 0.055)
    noise = [random.uniform(-1, 1) for _ in range(length)]
    shaped = highpass(lowpass(noise, 3200), 700)
    return [s * math.exp(-(i / RATE) * 190) for i, s in enumerate(shaped)]


def drop():
    """A droplet: pitch rising exponentially, which is what makes water sound
    like water. Everything else here either falls or holds."""
    out, phase = [], 0.0
    length = int(RATE * 0.32)
    for i in range(length):
        t = i / RATE
        freq = 420 * math.exp(t * 4.6)
        phase += 2 * math.pi * freq / RATE
        env = min(1, t / 0.003) * math.exp(-t * 15)
        out.append((math.sin(phase) + 0.12 * math.sin(2 * phase)) * env)
    return out


def wood():
    """A struck bar. Inharmonic partials, each decaying at its own rate, and
    an attack short enough to read as a hit rather than a note."""
    partials = [(1.00, 1.00, 22), (2.57, 0.42, 34), (4.94, 0.18, 48), (8.21, 0.07, 60)]
    root = 620
    out = []
    for i in range(int(RATE * 0.30)):
        t = i / RATE
        s = sum(gain * math.sin(2 * math.pi * root * ratio * t) * math.exp(-t * decay)
                for ratio, gain, decay in partials)
        out.append(s * min(1, t / 0.0008))
    return out


def bell():
    """FM. The modulation index falls away faster than the amplitude, so it
    starts metallic and settles into a tone, which is how a real bell behaves."""
    carrier, ratio = 660, 1.41   # inharmonic on purpose
    out = []
    for i in range(int(RATE * 1.30)):
        t = i / RATE
        index = 7.0 * math.exp(-t * 13)
        phase = 2 * math.pi * carrier * t + index * math.sin(2 * math.pi * carrier * ratio * t)
        out.append(math.sin(phase) * min(1, t / 0.002) * math.exp(-t * 3.6))
    return out


def glass():
    """Additive, with the partials detuned a couple of hertz apart so they beat
    against each other. That slow wobble is the shimmer."""
    partials = [(1.00, 1.00, 2.4), (2.76, 0.55, 3.1), (5.40, 0.30, 4.0), (8.93, 0.14, 5.2)]
    root = 1180
    out = []
    for i in range(int(RATE * 1.70)):
        t = i / RATE
        s = 0.0
        for index, (ratio, gain, decay) in enumerate(partials):
            freq = root * ratio
            s += gain * math.exp(-t * decay) * (
                math.sin(2 * math.pi * freq * t)
                + 0.6 * math.sin(2 * math.pi * (freq + 1.7 + index) * t)
            )
        out.append(s * min(1, t / 0.004))
    return out


def rise():
    """Three tones up a major triad. Melody carries meaning that timbre cannot:
    this one means it worked."""
    notes = [(0.000, 587.33), (0.075, 739.99), (0.150, 987.77)]
    out = []
    for i in range(int(RATE * 0.75)):
        t = i / RATE
        s = 0.0
        for start, freq in notes:
            dt = t - start
            if dt >= 0:
                s += (math.sin(2 * math.pi * freq * dt)
                      + 0.16 * math.sin(4 * math.pi * freq * dt)) \
                     * min(1, dt / 0.004) * math.exp(-dt * 11)
        out.append(math.tanh(s * 0.8))
    return out


def fall():
    """Two tones down a minor third, slower and rounder than rise. The inverse
    reading: something did not work."""
    notes = [(0.000, 659.26), (0.145, 554.37)]
    out = []
    for i in range(int(RATE * 0.95)):
        t = i / RATE
        s = 0.0
        for start, freq in notes:
            dt = t - start
            if dt >= 0:
                s += (math.sin(2 * math.pi * freq * dt)
                      + 0.30 * math.sin(math.pi * freq * dt)) \
                     * min(1, dt / 0.008) * math.exp(-dt * 7.5)
        out.append(math.tanh(s * 0.75))
    return out


def thump():
    """Sub sine with the pitch dropping away underneath it. On a laptop speaker
    this is nearly inaudible and on anything with a woofer you feel it. For
    things that should register without interrupting."""
    out, phase = [], 0.0
    for i in range(int(RATE * 0.42)):
        t = i / RATE
        freq = 58 + 62 * math.exp(-t * 26)
        phase += 2 * math.pi * freq / RATE
        out.append(math.sin(phase) * min(1, t / 0.006) * math.exp(-t * 9))
    return out


def alarm():
    """Three gated pulses with odd harmonics. Deliberately the least pleasant
    thing here. Reserve it for something actually being down."""
    out = []
    for i in range(int(RATE * 0.62)):
        t = i / RATE
        s = 0.0
        for pulse in range(3):
            dt = t - pulse * 0.135
            if 0 <= dt < 0.085:
                gate = min(1, dt / 0.004) * min(1, (0.085 - dt) / 0.010)
                s += (math.sin(2 * math.pi * 880 * dt)
                      + 0.34 * math.sin(2 * math.pi * 2640 * dt)
                      + 0.16 * math.sin(2 * math.pi * 4400 * dt)) * gate
        out.append(math.tanh(s * 0.9))
    return out


# ---------------------------------------------------------------- build

SOUNDS = [
    ("chirp", chirp, 1.00),
    ("tick", tick, 0.55),
    ("drop", drop, 0.80),
    ("wood", wood, 0.85),
    ("bell", bell, 0.80),
    ("glass", glass, 0.70),
    ("rise", rise, 0.90),
    ("fall", fall, 0.90),
    ("thump", thump, 1.00),
    ("alarm", alarm, 0.85),
]

if __name__ == "__main__":
    print(f"\n  writing to {HERE}\n")
    for name, build, trim in SOUNDS:
        write(name, build(), trim=trim)
    print()
