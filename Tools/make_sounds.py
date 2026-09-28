#!/usr/bin/env python3
"""Generates Shield's two tones.

catch.wav  — a latch closing. Low, soft, brief. Never an alert.
reveal.wav — its quieter, higher counterpart.

Both are synthesised rather than sampled so the repo carries no licensed audio.
"""
import math, struct, wave, os

SR = 44100

def env(t, dur, attack, decay_shape):
    if t < attack:
        return (t / attack) ** 0.6
    x = (t - attack) / max(dur - attack, 1e-6)
    return math.exp(-decay_shape * x) * (1 - x) ** 0.4

def render(path, dur, partials, attack, decay_shape, gain, drop=0.0):
    n = int(SR * dur)
    frames = []
    for i in range(n):
        t = i / SR
        e = env(t, dur, attack, decay_shape)
        # A gentle downward glide reads as "closing" rather than "arriving".
        bend = 1.0 - drop * (t / dur)
        s = 0.0
        for freq, amp, pdecay in partials:
            s += amp * math.exp(-pdecay * t) * math.sin(2 * math.pi * freq * bend * t)
        s *= e * gain
        # Soft saturation keeps the peak round instead of edgy.
        s = math.tanh(s * 1.4) / 1.4
        frames.append(s)

    # 4 ms fade out so there is no terminal click.
    fade = int(SR * 0.004)
    for i in range(fade):
        frames[-1 - i] *= i / fade

    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, v)) * 32000)) for v in frames))
    print("wrote", path, "%.0f ms" % (dur * 1000))

here = os.path.join(os.path.dirname(__file__), "..",
                    "Sources", "ShieldCore", "Resources")

# Low wooden latch: a fundamental near D3, a fifth above it, and a short
# body thump. No high partials at all, which is what keeps it off the
# "notification" shelf of the ear.
render(os.path.join(here, "catch.wav"),
       dur=0.34,
       partials=[(146.83, 0.55, 3.2),
                 (220.00, 0.30, 5.0),
                 (293.66, 0.14, 9.0),
                 (98.00,  0.26, 2.2)],
       attack=0.006, decay_shape=4.2, gain=0.72, drop=0.018)

# The counterpart: quieter, higher, lifts very slightly.
render(os.path.join(here, "reveal.wav"),
       dur=0.20,
       partials=[(587.33, 0.30, 6.0),
                 (880.00, 0.16, 9.0),
                 (1174.7, 0.06, 14.0)],
       attack=0.004, decay_shape=6.5, gain=0.34, drop=-0.012)
