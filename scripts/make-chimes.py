#!/usr/bin/env python3
"""Generates Holler's chimes into Resources/Sounds/. No dependencies.

  start.wav  the mic is live: a short, low tick at 350 Hz, Tink's character an
             octave down
  stop.wav   you let go: a warmer pluck at 220 Hz with a soft reverb tail

Both are kept low and filtered, with nothing bright on top, so they stay soft
on laptop and external speakers alike. They're synthesized here rather than copied from
macOS, so Holler owns them. The levels are final: the app plays them at full
volume.

Usage:
  scripts/make-chimes.py
"""

import math
import os
import struct
import wave

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")


def write(name, samples):
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))


def lowpass(x, cutoff):
    a = 1 - math.exp(-2 * math.pi * cutoff / SR)
    y, out = 0.0, []
    for s in x:
        y += a * (s - y)
        out.append(y)
    return out


def reverb(x, wet, tail):
    """A small Schroeder reverb: four parallel combs, then two allpasses."""
    n = len(x) + int(tail * SR)
    x = x + [0.0] * (n - len(x))
    out = [0.0] * n
    for d, g in ((1557, 0.80), (1617, 0.79), (1491, 0.81), (1422, 0.82)):
        buf = [0.0] * n
        for i in range(n):
            buf[i] = x[i] + (g * buf[i - d] if i >= d else 0)
            out[i] += buf[i] / 4
    for d, g in ((225, 0.5), (556, 0.5)):
        y = [0.0] * n
        for i in range(n):
            y[i] = -g * out[i] + (out[i - d] if i >= d else 0) + (g * y[i - d] if i >= d else 0)
        out = y
    return [(1 - wet) * a + wet * b for a, b in zip(x, out)]


def fade_out(x, secs):
    k = int(secs * SR)
    n = len(x)
    return [s * min(1, (n - i) / k) for i, s in enumerate(x)]


def normalize(x, peak):
    m = max(abs(s) for s in x) or 1
    return [s * peak / m for s in x]


def start():
    # Rise in 8 ms, ease to 75% over the next 37 ms, then fall away fast.
    out = []
    for i in range(int(0.12 * SR)):
        t = i / SR
        if t < 0.008:
            env = (t / 0.008) ** 2
        elif t < 0.045:
            env = 1 - 0.25 * (t - 0.008) / 0.037
        else:
            env = 0.75 * math.exp(-(t - 0.045) / 0.011)
        out.append(env * math.sin(2 * math.pi * 350 * t))
    return normalize(lowpass(out, 1400), 0.14)


def stop():
    # A 220 Hz pluck with a faint octave: 12 ms rise, then a 120 ms decay.
    out = []
    for i in range(int(0.5 * SR)):
        t = i / SR
        env = (min(1, t / 0.012) ** 2) * math.exp(-max(0, t - 0.012) / 0.12)
        out.append(env * (math.sin(2 * math.pi * 220 * t) + 0.1 * math.sin(2 * math.pi * 440 * t)))
    return normalize(fade_out(lowpass(reverb(out, wet=0.35, tail=0.8), 1400), 0.05), 0.17)


if __name__ == "__main__":
    write("start.wav", start())
    write("stop.wav", stop())
    print("Wrote start.wav and stop.wav to Resources/Sounds/")
