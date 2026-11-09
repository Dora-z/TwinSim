"""Synthesises the promo soundtrack (pad + arp + bass + soft kick + transition swells).
Usage: python3 promo/music.py out.wav [duration]"""
import sys, wave
import numpy as np

SR = 44100
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 54.0
SCENE_CUTS = [5, 11.5, 19, 26.5, 34, 40, 48.5]
BPM = 100
BEAT = 60 / BPM
N = int(SR * (DUR + 2))
t = np.arange(N) / SR
mix = np.zeros((N, 2))
rng = np.random.default_rng(7)

def hz(m): return 440 * 2 ** ((m - 69) / 12)

# chord progression, two bars each: Cmaj9, Am9, Fmaj9, G6sus
CHORDS = [[48, 55, 59, 62, 64], [45, 52, 55, 59, 60], [41, 48, 52, 55, 57], [43, 50, 55, 57, 62]]
BAR2 = BEAT * 8

def add(sig, start, pan=0.0):
    i = int(start * SR); j = min(N, i + len(sig))
    if j <= i: return
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    mix[i:j, 0] += sig[: j - i] * l * 1.4
    mix[i:j, 1] += sig[: j - i] * r * 1.4

# pad
k = 0; start = 0.0
while start < DUR:
    ch = CHORDS[k % 4]; ln = BAR2 + 1.5
    tt = np.arange(int(ln * SR)) / SR
    env = np.minimum(1, tt / 1.2) * np.minimum(1, np.maximum(0, (ln - tt) / 1.5))
    for n, m in enumerate(ch):
        f = hz(m + 12)
        for det, pan in ((-0.12, -0.6), (0.12, 0.6)):
            ph = 2 * np.pi * f * (1 + det / 100) * tt
            s = np.sin(ph) + 0.25 * np.sin(2 * ph) + 0.08 * np.sin(3 * ph)
            add(0.022 * env * s * (1 + 0.15 * np.sin(2 * np.pi * 0.25 * tt + n)), start, pan)
    start += BAR2; k += 1

# arpeggio (eighth notes) from 4.2 s to 49 s
step = BEAT / 2; i = 0; pos = 4.2
pattern = [0, 2, 3, 4, 3, 2, 1, 2]
while pos < 49.5:
    ch = CHORDS[int(pos // BAR2) % 4]
    m = ch[pattern[i % 8]] + 24
    tt = np.arange(int(0.9 * SR)) / SR
    env = np.exp(-tt * 6) * np.minimum(1, tt / 0.004)
    s = np.sin(2 * np.pi * hz(m) * tt) + 0.3 * np.sin(4 * np.pi * hz(m) * tt) * np.exp(-tt * 12)
    vel = 0.05 * (0.8 + 0.2 * (i % 2 == 0)) * min(1, (pos - 4.2) / 3)
    add(vel * env * s, pos, 0.35 * np.sin(i * 0.9))
    # echo
    add(vel * 0.35 * env * s, pos + BEAT * 0.75, -0.35 * np.sin(i * 0.9))
    pos += step; i += 1

# bass + kick from first cut to just before the outro
pos = 5.0; b = 0
while pos < 48.3:
    ch = CHORDS[int(pos // BAR2) % 4]
    tt = np.arange(int(0.55 * SR)) / SR
    kick_env = np.exp(-tt * 9)
    kick = np.sin(2 * np.pi * (45 * tt + 60 * (1 - np.exp(-tt * 30)) / 30)) * kick_env
    add(0.22 * kick, pos)
    if b % 2 == 0:
        bt = np.arange(int(BEAT * 1.9 * SR)) / SR
        benv = np.minimum(1, bt / 0.02) * np.exp(-bt * 1.2)
        add(0.09 * benv * np.sin(2 * np.pi * hz(ch[0] - 12) * bt), pos)
    # soft hat on off-beats
    ht = np.arange(int(0.08 * SR)) / SR
    hat = rng.standard_normal(len(ht)) * np.exp(-ht * 70)
    hat = np.diff(hat, prepend=0)  # crude high-pass
    add(0.025 * hat, pos + BEAT / 2, 0.3)
    pos += BEAT; b += 1

# transition swells (filtered noise rising into each cut) + soft impact
for c in SCENE_CUTS:
    ln = 0.9
    tt = np.arange(int(ln * SR)) / SR
    noise = rng.standard_normal(len(tt))
    # moving-average low-pass whose width shrinks → brighter as it rises
    out = np.zeros_like(noise); acc = 0.0
    for idx in range(len(noise)):
        a = 0.02 + 0.5 * (idx / len(noise)) ** 2
        acc += a * (noise[idx] - acc); out[idx] = acc
    env = (tt / ln) ** 2.2
    add(0.10 * out * env, c - ln, -0.2)
    add(0.10 * out * env, c - ln, 0.2)
    it = np.arange(int(1.2 * SR)) / SR
    add(0.10 * np.sin(2 * np.pi * 55 * it) * np.exp(-it * 4), c)

# final chord bloom for the outro
tt = np.arange(int(6 * SR)) / SR
env = np.minimum(1, tt / 0.05) * np.exp(-tt * 0.6)
for m in [48, 55, 59, 64, 67, 71]:
    add(0.035 * env * (np.sin(2 * np.pi * hz(m + 12) * tt) + 0.2 * np.sin(4 * np.pi * hz(m + 12) * tt)), 48.5)

# master: fade in/out, normalise
fade = np.minimum(1, t / 0.8) * np.clip((DUR - t) / 2.5, 0, 1)
mix *= fade[:, None]
mix = mix[: int(DUR * SR)]
mix /= np.max(np.abs(mix)) + 1e-9
mix *= 0.85
pcm = (mix * 32767).astype(np.int16)
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(pcm.tobytes())
print('wrote', sys.argv[1])
