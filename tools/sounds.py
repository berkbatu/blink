"""Synthesizes Blink's sounds (pure stdlib): chime (alert), pop (added), done (dismissed)."""
import math, struct, sys, wave, os

RATE = 44100
out = sys.argv[1]


def bell(buf, start, freq, amp, decay, length):
    """Additive bell: slightly inharmonic partials, each decaying faster than the last."""
    partials = [(1.0, 1.0, 1.0), (2.0, 0.45, 1.6), (3.01, 0.22, 2.4), (4.17, 0.12, 3.2), (5.43, 0.06, 4.0)]
    s0 = int(start * RATE)
    for i in range(int(length * RATE)):
        if s0 + i >= len(buf):
            break
        t = i / RATE
        attack = min(1.0, t / 0.004)
        v = 0.0
        for mult, a, d in partials:
            v += a * math.sin(2 * math.pi * freq * mult * t) * math.exp(-t * decay * d)
        buf[s0 + i] += amp * attack * v


def write(name, buf, peak=0.8):
    m = max(1e-9, max(abs(x) for x in buf))
    with wave.open(os.path.join(out, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(x / m * peak * 32767)) for x in buf))


# Chime: a bright rising A-major arpeggio with a sparkle on top.
chime = [0.0] * int(2.2 * RATE)
for i, (f, a) in enumerate([(880.0, 1.0), (1108.73, 0.9), (1318.51, 0.85), (1760.0, 0.55)]):
    bell(chime, i * 0.11, f, a, 2.2 if i < 3 else 1.6, 2.0)
write("chime.wav", chime, 0.85)

# Pop: tiny upward blip when a reminder is saved.
pop = [0.0] * int(0.16 * RATE)
phase = 0.0
for i in range(len(pop)):
    t = i / RATE
    f = 520 + 900 * (t / 0.16)
    phase += 2 * math.pi * f / RATE
    pop[i] = math.sin(phase) * math.exp(-t * 32) * min(1, t / 0.002)
write("pop.wav", pop, 0.45)

# Done: two warm notes falling into place.
done = [0.0] * int(1.0 * RATE)
bell(done, 0.0, 1318.51, 0.8, 4.0, 0.9)
bell(done, 0.09, 1760.0, 1.0, 3.2, 0.9)
write("done.wav", done, 0.6)


# Engine: a synthesized inline-six cold start — starter crank, catch, flare, two blips with crackles, burbly idle.
def engine():
    import random
    random.seed(6)
    dur = 5.2
    n = int(dur * RATE)
    buf = [0.0] * n

    # (time, rpm, throttle) keyframes after the engine catches at 1.0s
    keys = [(1.0, 450, 1.0), (1.22, 3100, 1.0), (1.55, 1700, 0.25), (2.05, 850, 0.2), (2.5, 820, 0.2),
            (2.72, 5400, 1.0), (3.05, 1600, 0.0), (3.35, 850, 0.2), (3.5, 840, 0.25),
            (3.78, 6400, 1.0), (4.2, 1500, 0.0), (4.6, 800, 0.2), (5.2, 760, 0.15)]

    def at(t):
        if t <= keys[0][0]:
            return keys[0][1], keys[0][2]
        for (t0, r0, h0), (t1, r1, h1) in zip(keys, keys[1:]):
            if t <= t1:
                x = (t - t0) / (t1 - t0)
                x = 0.5 - 0.5 * math.cos(math.pi * x)  # ease
                return r0 + (r1 - r0) * x, h0 + (h1 - h0) * x
        return keys[-1][1], keys[-1][2]

    def tmpl(length, fn):
        return [fn(j / RATE) for j in range(int(length * RATE))]

    noise = lambda: random.uniform(-1, 1)
    dark = tmpl(0.05, lambda t: math.exp(-t / 0.011) * math.sin(2 * math.pi * 92 * t)
                + 0.35 * math.exp(-t / 0.005) * math.sin(2 * math.pi * 300 * t))
    bright = tmpl(0.05, lambda t: math.exp(-t / 0.008) * math.sin(2 * math.pi * 120 * t)
                  + 0.7 * math.exp(-t / 0.004) * math.sin(2 * math.pi * 410 * t)
                  + 0.35 * math.exp(-t / 0.0018) * math.sin(2 * math.pi * 1500 * t))
    hiss = [tmpl(0.012, lambda t: math.exp(-t / 0.0015) * noise()) for _ in range(12)]
    crack = [tmpl(0.04, lambda t: 1.5 * math.exp(-t / 0.003) * noise()
                  + 0.6 * math.exp(-t / 0.015) * math.sin(2 * math.pi * 170 * t)) for _ in range(6)]
    thump = tmpl(0.12, lambda t: math.exp(-t / 0.035) * math.sin(2 * math.pi * 58 * t) + 0.3 * math.exp(-t / 0.004) * noise())
    boom = tmpl(0.5, lambda t: math.exp(-t / 0.13) * math.sin(2 * math.pi * 44 * t * (1 - t * 0.4)))

    def add(start, tpl, amp):
        s0 = int(start * RATE)
        for j, v in enumerate(tpl):
            if s0 + j >= n:
                break
            buf[s0 + j] += amp * v

    # 1) Starter: whining motor + compression strokes slowing it down
    for i in range(int(1.0 * RATE)):
        t = i / RATE
        f = 820 + 140 * math.sin(2 * math.pi * 8.5 * t)
        env = min(1, t / 0.05)
        buf[i] += env * 0.07 * (math.sin(2 * math.pi * f * t) + 0.4 * math.sin(4 * math.pi * f * t))
    k = 0.04
    while k < 1.0:
        add(k, thump, 0.55 + random.uniform(-0.1, 0.1))
        k += 1 / 8.5

    # 2) Catch!
    add(0.98, boom, 1.4)

    # 3) Combustion: 3 firings per crank revolution on an inline six
    phase, next_fire = 0.0, 0.0
    prev_rpm = 0
    lp = 0.0
    for i in range(int(0.98 * RATE), n):
        t = i / RATE
        rpm, th = at(t)
        phase += rpm / 60 / RATE * 3
        decel = rpm < prev_rpm - 0.02 and th < 0.15
        prev_rpm = rpm
        if phase >= next_fire:
            next_fire += 1 + random.uniform(-0.06, 0.06)  # tiny unevenness = lumpy, alive
            a = (0.38 + 0.75 * th) * random.uniform(0.85, 1.15)
            s0 = i
            for j in range(len(dark)):
                if s0 + j >= n:
                    break
                buf[s0 + j] += a * ((1 - th) * dark[j] + th * bright[j])
            add(t, random.choice(hiss), 0.25 * a)
            if decel and rpm > 1000 and random.random() < 0.3:
                add(t + random.uniform(0, 0.01), random.choice(crack), random.uniform(0.6, 1.2))
        # intake roar: noise that brightens with rpm
        alpha = min(0.9, 0.04 + rpm / 9000)
        lp += alpha * (noise() - lp)
        buf[i] += lp * th * 0.22 * (rpm / 6000)

    # 4) Grit + fade
    out_buf = []
    for i, v in enumerate(buf):
        t = i / RATE
        fade = 1 if t < dur - 0.6 else max(0, (dur - t) / 0.6)
        out_buf.append(math.tanh(1.7 * v) * fade)
    write("engine.wav", out_buf, 0.95)


engine()
