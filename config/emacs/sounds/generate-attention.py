#!/usr/bin/env python3
"""Write our soft two-note chime: deterministic, integer-only PCM synthesis.

No randomness, floating point, timestamps, third-party modules or audio tools.
The WAV is built by Nix, not checked in or generated during activation.
"""

import struct
import sys
import wave

RATE = 24_000
PEAK = 4_400


def tone_sample(index: int, frequency: int, length: int) -> int:
    """Approximate a sine using Bhaskara I's rational formula and an envelope."""
    phase = (index * frequency) % RATE
    sign = 1 if phase < RATE // 2 else -1
    phase %= RATE // 2
    product = phase * (RATE // 2 - phase)
    sine = sign * PEAK * 16 * product // (5 * (RATE // 2) ** 2 - 4 * product)
    attack = min(index, RATE * 15 // 1000)
    remaining = length - 1 - index
    return sine * attack * remaining**2 // ((RATE * 15 // 1000) * length**2)


def generate(path: str) -> None:
    samples = [0] * (RATE // 2)
    length = RATE // 4
    for start, frequency in ((0, 660), (RATE // 4, 880)):
        for index in range(length):
            samples[start + index] = tone_sample(index, frequency, length)
    with wave.open(path, "wb") as output:
        output.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(struct.pack(f"<{len(samples)}h", *samples))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} OUTPUT.wav")
    generate(sys.argv[1])