"""Regenerates the README art in docs/assets/: an animated hero of real captures, and animated SVG cards.

    python3 docs/assets/make_svgs.py              # stdlib only, from docs/assets/readme-src/
    python3 docs/assets/make_svgs.py --sources    # first rebuilds readme-src/ from the full captures (Pillow)
    python3 docs/assets/make_svgs.py --demo       # the made-up card set, into docs/assets/demo/

Everything is SMIL (<animate>, <animateTransform>), so it plays inside GitHub's <img> sandbox: no scripts, no
external files, no webfonts. Pictures go in as base64 data URIs.

  - Hero: two iPhones and an Apple Watch drawn as frames; everything on their screens is a real capture
    (readme-src/phone-*.jpg, readme-src/watch-now-playing.jpg, the watch app's own page around the same song), crossfading slowly.
  - Cards (the README's set): only real content. Lyrics, Radar and Downloads are real captures panning slowly in a
    window (readme-src/card-*.jpg); the devices card is the real watch page beside the iPhone playing the same song;
    Made For You shows real covers cut from the Home shelf (readme-src/cover-*.jpg); the equalizer is drawn from its
    real bands and preset gains (Components/EqualizerView.swift, Models.swift) and names no song.
  - Demo set (--demo): the same six cards drawn after the app with entirely made-up songs, artists and lyrics (no
    real names), kept in docs/assets/demo/ in case the real captures ever have to go.

Writes aura-hero.svg, aura-hero-light.svg, card-*.svg and btn-*.svg (plus -fr buttons) and prints sizes.
"""
import base64
import sys
import unicodedata
from pathlib import Path

OUT = Path(__file__).parent
ACCENT = "#EB534D"          # brand coral
COVER_RED = "#FF3B54"       # coverRed in CoverKit.swift: the ▶ on the covers
BG, BG2, EDGE = "#121212", "#0D0D0D", "#262626"
FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Display','Helvetica Neue',Arial,sans-serif"
CAP = 0.72                  # cap height / font size for the stack above
COND = 0.62                 # Archivo Extra Condensed Black against a heavy grotesque
WIDE = 1.2                  # Archivo Expanded against the same

# --- text metrics (Helvetica widths per 1000 em: close enough to SF to place things) ------------------------
_LOW = "abcdefghijklmnopqrstuvwxyz"
_UP = _LOW.upper()
REG = dict(zip(_LOW, [556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333,
                      500, 278, 556, 500, 722, 500, 500, 500]))
BOLD = dict(zip(_LOW, [556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389,
                       556, 333, 611, 556, 778, 556, 556, 500]))
_CAPS = [722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722,
         667, 944, 667, 667, 611]
for _t in (REG, BOLD):
    _t.update(zip(_UP, _CAPS))
    _t.update({c: 556 for c in "0123456789"})
    _t.update({" ": 278, ".": 278, ",": 278, "-": 333, "'": 238, "’": 278, "·": 278, "&": 722, "+": 584,
               "−": 584, ":": 333, "(": 333, ")": 333, "/": 278, "…": 1000, "!": 333, "?": 611})


def width(s, size, bold=False):
    t = BOLD if bold else REG
    base = (unicodedata.normalize("NFD", c)[0] for c in s)
    return sum(t.get(c, 600) for c in base) / 1000 * size


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size, fill="#fff", weight=400, anchor=None, op=None, extra=""):
    a = f' text-anchor="{anchor}"' if anchor else ""
    o = f' fill-opacity="{op}"' if op is not None else ""
    return (f'<text x="{x:g}" y="{y:g}" font-family="{FONT}" font-size="{size:g}" font-weight="{weight}" '
            f'fill="{fill}"{o}{a}{extra}>{esc(s)}</text>')


def svg(w, h, body, title, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img">'
            f'<title>{esc(title)}</title>{f"<defs>{defs}</defs>" if defs else ""}{body}</svg>\n')


# --- SMIL ----------------------------------------------------------------------------------------------------
EASE = ".45 0 .25 1"


def kt(t, total):
    return f"{min(1, max(0, t / total)):.4f}".rstrip("0").rstrip(".") or "0"


def anim(attr, kf, total, ease=True, tag="animate", extra=""):
    """kf = [(t, value)] from 0 to total; equal times make a jump. Eased (or linear) between keys."""
    times = ";".join(kt(t, total) for t, _ in kf)
    vals = ";".join(f"{v:g}" if isinstance(v, (int, float)) else str(v) for _, v in kf)
    mode = (f'calcMode="spline" keySplines="{";".join([EASE] * (len(kf) - 1))}"' if ease else 'calcMode="linear"')
    return (f'<{tag} attributeName="{attr}" values="{vals}" keyTimes="{times}" dur="{total:g}s" {mode} '
            f'repeatCount="indefinite"{extra}/>')


def slide(kf, total, ease=True):
    """kf = [(t, (dx, dy))] → animateTransform translate."""
    return anim("transform", [(t, f"{x:g} {y:g}") for t, (x, y) in kf], total, ease, "animateTransform",
                ' type="translate"')


# --- icons (24-unit boxes, SF Symbols-like) ------------------------------------------------------------------
ICONS = {
    "play": ("f", "M7 4.8v14.4c0 .9 1 1.4 1.7.9l11-7.2a1.1 1.1 0 0 0 0-1.8l-11-7.2C8 3.4 7 3.9 7 4.8z"),
    "pause": ("f", "M6 5.2C6 4.5 6.5 4 7.2 4h1.6c.7 0 1.2.5 1.2 1.2v13.6c0 .7-.5 1.2-1.2 1.2H7.2C6.5 20 6 19.5 6 18.8z"
                   "M14 5.2c0-.7.5-1.2 1.2-1.2h1.6c.7 0 1.2.5 1.2 1.2v13.6c0 .7-.5 1.2-1.2 1.2h-1.6c-.7 0-1.2-.5-1.2-1.2z"),
    "back": ("f", "M11.5 6.3v11.4c0 .8-.9 1.2-1.5.7L3.4 13a1.3 1.3 0 0 1 0-2L10 5.6c.6-.5 1.5-.1 1.5.7z"
                  "M21 6.3v11.4c0 .8-.9 1.2-1.5.7L12.9 13a1.3 1.3 0 0 1 0-2l6.6-5.4c.6-.5 1.5-.1 1.5.7z"),
    "fwd": ("f", "M12.5 6.3v11.4c0 .8.9 1.2 1.5.7l6.6-5.4a1.3 1.3 0 0 0 0-2L14 5.6c-.6-.5-1.5-.1-1.5.7z"
                 "M3 6.3v11.4c0 .8.9 1.2 1.5.7l6.6-5.4a1.3 1.3 0 0 0 0-2L4.5 5.6C3.9 5.1 3 5.5 3 6.3z"),
    "shuffle": ("s", "M3 7h3.5c2.5 0 3.7 1.3 5 3.5l1 1.8c1.3 2.2 2.5 3.7 5 3.7H21M3 17h3.5c1.6 0 2.7-.6 3.6-1.7"
                     "M14 8.7C14.9 7.6 16 7 17.5 7H21M18.5 4.5 21 7l-2.5 2.5M18.5 14.5 21 17l-2.5 2.5"),
    "repeat": ("s", "M4 11.5V9.5A3.5 3.5 0 0 1 7.5 6H20M17 3l3 3-3 3M20 12.5v2A3.5 3.5 0 0 1 16.5 18H4M7 21l-3-3 3-3"),
    "heart": ("s", "M12 20s-7.5-4.6-7.5-10.2A4.3 4.3 0 0 1 12 7.2a4.3 4.3 0 0 1 7.5 2.6C19.5 15.4 12 20 12 20z"),
    "heartf": ("f", "M12 20.5s-8-4.8-8-10.6A4.6 4.6 0 0 1 12 7a4.6 4.6 0 0 1 8 2.9c0 5.8-8 10.6-8 10.6z"),
    "dots": ("f", "M3.3 12a1.7 1.7 0 1 0 3.4 0 1.7 1.7 0 1 0-3.4 0M10.3 12a1.7 1.7 0 1 0 3.4 0 1.7 1.7 0 1 0-3.4 0"
                  "M17.3 12a1.7 1.7 0 1 0 3.4 0 1.7 1.7 0 1 0-3.4 0"),
    "quote": ("s", "M6 4h12a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3h-6l-5 3.5V18H6a3 3 0 0 1-3-3V7a3 3 0 0 1 3-3zM9 9v3M15 9v3"),
    "airplay": ("s", "M6.5 17H5a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3h14a3 3 0 0 1 3 3v8a3 3 0 0 1-3 3h-1.5M12 14.5l4.5 6h-9z"),
    "list": ("s", "M9 6h12M9 12h12M9 18h12M4 6h.5M4 12h.5M4 18h.5"),
    "note": ("f", "M9 17.2V6.6c0-.6.4-1.1 1-1.2l8.8-1.8c.6-.1 1.2.4 1.2 1v10.5a3 3 0 1 1-2-2.8V8l-7 1.5v7.7a3 3 0 1 1-2-2.8z"),
    "speaker": ("f", "M4 9.5h3.2L11.5 6v12l-4.3-3.5H4zM14.5 9a4.2 4.2 0 0 1 0 6M17 6.5a7.8 7.8 0 0 1 0 11"),
    "download": ("s", "M12 3.5v11.5M7 10.5l5 5 5-5M4.5 20h15"),
    "grid": ("s", "M4 4h6.5v6.5H4zM13.5 4H20v6.5h-6.5zM4 13.5h6.5V20H4zM13.5 13.5H20V20h-6.5z"),
    "builds": ("s", "M3.5 5.5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2zM12.5 5.5a2 2 0 0 1 2-2h4"
                    "a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2zM6.5 17.5h1M15.5 17.5h1"),
    "code": ("s", "M8 7l-5 5 5 5M16 7l5 5-5 5M14 4.5l-4 15"),
    "check": ("s", "M7 12.5l3.2 3.2L17 9"),
}


def icon(name, cx, cy, size, color="#fff", sw=2, op=None):
    kind, d = ICONS[name]
    o = f' opacity="{op}"' if op is not None else ""
    paint = (f'fill="{color}"' if kind == "f" else
             f'fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"')
    if name == "speaker":  # a filled cone with stroked waves
        return (f'<g transform="translate({cx - size / 2:g} {cy - size / 2:g}) scale({size / 24:g})"{o}>'
                f'<path d="M4 9.5h3.2L11.5 6v12l-4.3-3.5H4z" fill="{color}"/><path d="M14.5 9a4.2 4.2 0 0 1 0 6'
                f'M17 6.5a7.8 7.8 0 0 1 0 11" fill="none" stroke="{color}" stroke-width="2" stroke-linecap="round"/></g>')
    return (f'<path transform="translate({cx - size / 2:g} {cy - size / 2:g}) scale({size / 24:g})" d="{d}" '
            f'{paint}{o}/>')


# --- covers (Components/Covers) ------------------------------------------------------------------------------
PLAY_MARK = "M0 3.5Q0 0 3.05 1.72L19.95 11.28Q23 13 19.95 14.72L3.05 24.28Q0 26 0 22.5Z"   # viewBox 23x26
FIGURE = '<circle cx="50" cy="39" r="17"/><path d="M13 104C13 76 29 63 50 63S87 76 87 104Z"/>'  # viewBox 100


def fit(s, column, max_cap, squeeze=COND):
    """CoverMetrics.fit: the cap height that makes `s` span the column, capped."""
    return min(max_cap, column / (width(s, 1, True) * squeeze) * CAP)


def cap_text(x, top, s, cap, fill, squeeze=COND, weight=900, track=0.0):
    """Text whose box is its cap height: `top` is the top of the capitals. Returns (svg, width)."""
    fs = cap / CAP
    w = width(s, fs, True) * squeeze + track * max(0, len(s) - 1)
    return (f'<text x="{x:.2f}" y="{top + cap:.2f}" font-family="{FONT}" font-size="{fs:.2f}" font-weight="{weight}" '
            f'fill="{fill}" textLength="{w:.2f}" lengthAdjust="spacingAndGlyphs">{esc(s)}</text>'), w


def lockup(x, top, label, s, color, mark=COVER_RED):
    """▶ LABEL, top-left on every cover (CoverLockup)."""
    size = s * 0.042
    cap = size * CAP
    mw, mh = cap * 1.15, cap * 1.3
    out = (f'<path transform="translate({x:.2f} {top + cap / 2 - mh / 2:.2f}) scale({mw / 23:.4f} {mh / 26:.4f})" '
           f'd="{PLAY_MARK}" fill="{mark}"/>')
    if label:
        out += cap_text(x + mw + cap * 0.6, top, label.upper(), cap, color, WIDE, 900, size * 0.06)[0]
    return out


def framed(uid, x, y, s, body, r=None):
    r = s * 0.07 if r is None else r
    return (f'<clipPath id="{uid}"><rect width="{s:g}" height="{s:g}" rx="{r:.1f}"/></clipPath>'
            f'<g transform="translate({x:g} {y:g})"><g clip-path="url(#{uid})">{body}</g></g>')


def cover_genre(uid, x, y, s, dark, light, words, kicker="Mix", art=None):
    m, col = s * 0.06, s * 0.88
    art = art if art is not None else (
        f'<g transform="translate({s * 0.2:.1f} {s * 0.06:.1f}) scale({s * 0.0085:.4f})" fill="{light}" '
        f'fill-opacity=".85">{FIGURE}</g>')
    body = (f'<linearGradient id="{uid}g" x1="0" y1="0" x2="0" y2="1"><stop offset=".4" stop-color="{dark}" '
            f'stop-opacity="0"/><stop offset=".85" stop-color="{dark}"/></linearGradient>'
            f'<rect width="{s:g}" height="{s:g}" fill="{dark}"/>{art}'
            f'<rect width="{s:g}" height="{s:g}" fill="url(#{uid}g)"/>' + lockup(m, m, kicker, s, light))
    caps = [fit(w.upper(), col, s * 0.3) for w in words]
    top = s - m - sum(caps) - s * 0.03 * (len(words) - 1)
    for w, c in zip(words, caps):
        body += cap_text(m, top, w.upper(), c, light)[0]
        top += c + s * 0.03
    return framed(uid, x, y, s, body)


# --- lyrics (word by word, the line in focus sharp, the others dimmed and blurred) ---------------------------
OPACITY = {0: 1, 1: 0.42, 2: 0.2, 3: 0.1, 4: 0.05}
BLUR = {0: 0, 1: 1.1, 2: 2.2, 3: 2.8, 4: 3.2}
UNSUNG = 0.35


def lyrics(uid, lines, x, yc, size, lh, step, fill, move=0.55, lead=0.35, reach=2):
    """Scrolls `lines` round and round, one per `step` seconds; returns (defs, body, total)."""
    n = len(lines)
    total = round(n * step, 3)
    ts, ss = [0.0], [0]
    for k in range(1, n + 1):
        ts += [k * step - move, k * step]
        ss += [k - 1, k]
    defs, body = "", ""
    for j in range(-reach, n + reach + 1):
        ops = [OPACITY.get(abs(j - s), 0) if abs(j - s) <= reach else 0 for s in ss]
        if not any(ops):
            continue
        blur = [BLUR.get(abs(j - s), 3) for s in ss]
        defs += (f'<filter id="{uid}b{j + reach}" x="-5%" y="-60%" width="110%" height="220%"><feGaussianBlur '
                 f'stdDeviation="{blur[0]}">{anim("stdDeviation", list(zip(ts, blur)), total)}</feGaussianBlur></filter>')
        words = lines[j % n].split()
        chars = [len(w) + 1 for w in words]
        spans = ""
        for i, w in enumerate(words):
            sung = j * step + lead + (step - lead - 0.9) * sum(chars[:i]) / sum(chars)
            if j == 0:
                kf = [(0, UNSUNG), (sung, UNSUNG), (sung + 0.12, 1), (total, 1)]
            elif 0 < j < n:
                kf = [(0, 1), (j * step - move, 1), (j * step, UNSUNG), (sung, UNSUNG), (sung + 0.12, 1), (total, 1)]
            elif j == n:
                kf = [(0, 1), (total - move, 1), (total, UNSUNG)]
            else:
                kf = None
            a = anim("fill-opacity", kf, total, ease=False) if kf else ""
            spans += f'<tspan fill-opacity="{kf[0][1] if kf else 1}">{esc(w)}{a}</tspan> '
        body += (f'<g filter="url(#{uid}b{j + reach})" opacity="{ops[0]}">{anim("opacity", list(zip(ts, ops)), total)}'
                 f'<text x="{x:g}" y="{yc + j * lh + size * 0.36:.1f}" font-family="{FONT}" font-size="{size:g}" '
                 f'font-weight="700" fill="{fill}">{spans.rstrip()}</text></g>')
    scroll = slide([(t, (0, -s * lh)) for t, s in zip(ts, ss)], total)
    return defs, f'<g>{scroll}{body}</g>', total


def fade_mask(uid, x, y, w, h, edge):
    e = edge / h
    return (f'<linearGradient id="{uid}mg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/>'
            f'<stop offset="{e:.3f}" stop-color="#fff"/><stop offset="{1 - e:.3f}" stop-color="#fff"/>'
            f'<stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>'
            f'<mask id="{uid}m" maskUnits="userSpaceOnUse" x="{x}" y="{y}" width="{w}" height="{h}">'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#{uid}mg)"/></mask>')


SONG = ("Midnight Signals", "Neon Harbour")
LINES = ["Static on the harbour line", "your voice comes in slow", "every light on the water",
         "spells your name tonight", "so I stay on the line"]
SUN = ("#1A1150", "#FF6FB5")  # CoverPalette.duotones[0]


# --- devices -------------------------------------------------------------------------------------------------
def backdrop(uid, w, h, blobs, veil=0.3, blur=None):
    """Now Playing's blurred-cover backdrop: colour blobs, a heavy blur, a dark veil."""
    b = blur or max(w, h) * 0.12
    shapes = "".join(f'<ellipse cx="{w * cx:.1f}" cy="{h * cy:.1f}" rx="{w * rx:.1f}" ry="{h * ry:.1f}" fill="{c}"/>'
                     for cx, cy, rx, ry, c in blobs)
    return (f'<filter id="{uid}bd" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="{b:.1f}"/>'
            f'</filter><rect width="{w}" height="{h}" fill="#141024"/><g filter="url(#{uid}bd)">{shapes}</g>'
            f'<rect width="{w}" height="{h}" fill="#000" fill-opacity="{veil}"/>')


BLOBS = [(0.2, 0.18, 0.55, 0.3, "#5B2A86"), (0.85, 0.3, 0.45, 0.28, "#FF6FB5"),
         (0.3, 0.75, 0.6, 0.3, "#1A1150"), (0.9, 0.85, 0.5, 0.25, ACCENT)]


def shell(uid, x, y, w, h, r, bezel, light, inner):
    """A device body around a screen of (w, h)."""
    top, bot, edge = ("#F1F1F3", "#C9C9CE", "#B8B8BE") if light else ("#3A3A3D", "#141416", "#4A4A4E")
    return (f'<linearGradient id="{uid}sh" x1="0" y1="0" x2=".4" y2="1"><stop offset="0" stop-color="{top}"/>'
            f'<stop offset="1" stop-color="{bot}"/></linearGradient>'
            f'<rect x="{x}" y="{y}" width="{w + 2 * bezel}" height="{h + 2 * bezel}" rx="{r + bezel}" fill="url(#{uid}sh)" '
            f'stroke="{edge}"/>'
            f'<rect x="{x + bezel - 3}" y="{y + bezel - 3}" width="{w + 6}" height="{h + 6}" rx="{r + 3}" fill="#000"/>'
            f'<clipPath id="{uid}sc"><rect width="{w}" height="{h}" rx="{r}"/></clipPath>'
            f'<g transform="translate({x + bezel} {y + bezel})"><g clip-path="url(#{uid}sc)">{inner}</g></g>')


def watch_now_playing(uid, w, h, title, artist, blobs=BLOBS, prog=((0, 0.32),)):
    """The watch app's Now Playing; `prog` = [(t, fraction)] animates the ring round the play button."""
    out = backdrop(uid, w, h, blobs, veil=0.22)
    k = w / 200
    for cx in (24 * k, w - 24 * k):
        out += f'<circle cx="{cx:.1f}" cy="{24 * k:.1f}" r="{15 * k:.1f}" fill="#fff" fill-opacity=".16"/>'
    out += icon("note", 24 * k, 24 * k, 15 * k)
    out += (f'<circle cx="{w - 24 * k:.1f}" cy="{24 * k:.1f}" r="{13 * k:.1f}" fill="none" stroke="#FF2D55" '
            f'stroke-width="{2.4 * k:.1f}" stroke-dasharray="{2 * 3.1416 * 13 * k * 0.7:.1f} 999" '
            f'transform="rotate(-200 {w - 24 * k:.1f} {24 * k:.1f})" stroke-linecap="round"/>')
    out += icon("speaker", w - 24 * k, 24 * k, 13 * k)
    out += text(w / 2, 30 * k, "10:09", 17 * k, weight=600, anchor="middle")
    out += text(16 * k, 80 * k, title, 16 * k, weight=700) + text(16 * k, 101 * k, artist, 16 * k, op=0.72)
    out += icon("heartf", w - 20 * k, 76 * k, 20 * k, "#FF4D6D")
    ty = 150 * k
    rr = 26 * k
    circ = 2 * 3.1416 * rr
    ring = prog[0][1]
    ring_anim = (anim("stroke-dashoffset", [(t, round(circ * (1 - p), 1)) for t, p in prog], prog[-1][0], ease=False)
                 if len(prog) > 1 else "")
    out += (f'<circle cx="{w / 2:.1f}" cy="{ty:.1f}" r="{rr:.1f}" fill="#fff" fill-opacity=".16"/>'
            f'<circle cx="{w / 2:.1f}" cy="{ty:.1f}" r="{rr:.1f}" fill="none" stroke="#fff" stroke-opacity=".25" '
            f'stroke-width="{2 * k:.1f}"/><circle cx="{w / 2:.1f}" cy="{ty:.1f}" r="{rr:.1f}" fill="none" stroke="#fff" '
            f'stroke-width="{2 * k:.1f}" stroke-dasharray="{circ:.1f}" stroke-dashoffset="{circ * (1 - ring):.1f}" '
            f'stroke-linecap="round" transform="rotate(-90 {w / 2:.1f} {ty:.1f})">{ring_anim}</circle>')
    out += icon("pause", w / 2, ty, 22 * k) + icon("back", 36 * k, ty, 28 * k) + icon("fwd", w - 36 * k, ty, 28 * k)
    for cx, n in ((24 * k, "quote"), (w - 24 * k, "list")):
        out += (f'<circle cx="{cx:.1f}" cy="{h - 24 * k:.1f}" r="{15 * k:.1f}" fill="#fff" fill-opacity=".16"/>'
                + icon(n, cx, h - 24 * k, 15 * k, sw=2))
    return out


def watch(uid, x, y, w, h, light, inner, band=34):
    """An Apple Watch: band stubs, crown, the case around a w×h screen."""
    bt, bb = ("#D6D6DB", "#B5B5BC") if light else ("#2A2A2D", "#19191B")
    cw = w + 16
    band = (f'<linearGradient id="{uid}bn" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{bt}"/>'
            f'<stop offset="1" stop-color="{bb}"/></linearGradient>'
            f'<path d="M{x + 14} {y + 8}L{x + 20} {y - band}h{cw - 40}L{x + cw - 14} {y + 8}z" fill="url(#{uid}bn)"/>'
            f'<path d="M{x + 14} {y + h + 8}L{x + 20} {y + h + 16 + band}h{cw - 40}L{x + cw - 14} {y + h + 8}z" '
            f'fill="url(#{uid}bn)"/>')
    crown = (f'<rect x="{x + cw - 2}" y="{y + h * 0.28:.1f}" width="7" height="{h * 0.2:.1f}" rx="2.5" fill="{bt}" '
             f'stroke="{bb}"/><rect x="{x + cw - 1}" y="{y + h * 0.58:.1f}" width="4" height="{h * 0.2:.1f}" rx="2" fill="{bb}"/>')
    return band + crown + shell(uid, x, y, w, h, w * 0.22, 8, light, inner)


# --- real captures (docs/assets/readme-src/) -----------------------------------------------------------------
SRC = OUT / "readme-src"
# `--sources` rebuilds readme-src/ from the full-size device captures, which live outside the repository
# (the 'Aura Screenshots' folders at the repo root are local-only); it needs Pillow. Everything else is stdlib.
PHONE_PX, COVER_PX, CARD_PX = 480, 240, 400
FULL = (0, 0, 1206, 2622)          # a whole iPhone capture
BELOW_BAR = (0, 300, 1206, 2622)   # the same without the status bar
CAPTURES = {  # name: (capture, crop box, width in px)
    "phone-now-playing.jpg": ("Aura Screenshots 2026-10-01/1-now-playing.png", FULL, PHONE_PX),
    "phone-lyrics.jpg": ("Aura Screenshots 2026-10-01/4-lyrics.png", FULL, PHONE_PX),
    "phone-home.jpg": ("Aura Screenshots 2026-10-02/home-real.png", FULL, PHONE_PX),
    "phone-radio.jpg": ("Aura Screenshots 2026-10-01/3-radio.png", FULL, PHONE_PX),
    "phone-offline.jpg": ("Aura Screenshots 2026-10-01/7-offline.png", FULL, PHONE_PX),
    # Made For You covers, cut from raw Home captures: the shelf's two fully visible squares
    "cover-radar-1.jpg": ("Aura Screenshots 2026-10-02/home-real-raw.png", (48, 950, 498, 1400), COVER_PX),
    "cover-afternoon-1.jpg": ("Aura Screenshots 2026-10-02/home-real-raw.png", (540, 950, 990, 1400), COVER_PX),
    "cover-radar-2.jpg": ("Aura Screenshots 2026-10-01/2-home-raw.png", (48, 950, 498, 1400), COVER_PX),
    "cover-afternoon-2.jpg": ("Aura Screenshots 2026-10-01/2-home-raw.png", (540, 950, 990, 1400), COVER_PX),
    # the cards' screens: raw captures, the status bar cut where a card shows the screen bare
    "card-lyrics.jpg": ("Aura Screenshots 2026-10-01/4-lyrics-raw.png", (0, 330, 1206, 2430), CARD_PX),
    "card-radar.jpg": ("Aura Screenshots 2026-09-26/2-radar.png", BELOW_BAR, CARD_PX),
    "card-offline.jpg": ("Aura Screenshots 2026-10-01/7-offline-raw.png", BELOW_BAR, CARD_PX),
    "card-now-playing.jpg": ("Aura Screenshots 2026-10-01/1-now-playing-raw.png", FULL, 240),
}


def aspect(name):
    """height / width of a readme-src picture, from its crop box (no image library needed)."""
    x0, y0, x1, y1 = CAPTURES[name][1]
    return (y1 - y0) / (x1 - x0)


def make_sources():
    from PIL import Image
    root = OUT.parent.parent
    SRC.mkdir(exist_ok=True)
    for name, (path, box, w) in CAPTURES.items():
        im = Image.open(root / path).convert("RGB").crop(box)
        im = im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)
        im.save(SRC / name, "JPEG", quality=80, optimize=True, progressive=True)
        print(f"readme-src/{name:24} {(SRC / name).stat().st_size / 1024:5.1f} KB")


def data_uri(path):
    kind = "webp" if path.suffix == ".webp" else "jpeg"
    return f"data:image/{kind};base64," + base64.b64encode(path.read_bytes()).decode()


def picture(uri, w, h, extra=""):
    return f'<image href="{uri}" width="{w:g}" height="{h:g}" preserveAspectRatio="xMidYMid slice"{extra}/>'


def crossfade(layers, T, fade=1.0):
    """Shows `layers` in turn, T / n seconds each. The first stays underneath; each later one fades in over the
    one before, which drops away once covered; the last fades out to reveal the first again."""
    n, seg = len(layers), T / len(layers)
    out = layers[0]
    for k in range(1, n):
        on = k * seg
        if k < n - 1:
            off = (k + 1) * seg
            kf = [(0, 0), (on - fade, 0), (on, 1), (off, 1), (off + 0.01, 0), (T, 0)]
        else:
            kf = [(0, 0), (on - fade, 0), (on, 1), (T - fade, 1), (T, 0)]
        out += f'<g opacity="0">{anim("opacity", kf, T)}{layers[k]}</g>'
    return out


# --- hero: two iPhones and an Apple Watch, real captures crossfading inside them ---------------------------
PHONE_W, PHONE_H, PHONE_R, PHONE_BEZEL = 230, 500, 33, 9   # 1206 × 2622 captures
WATCH_W, WATCH_H = 150, 179                                # 416 × 496 renders


def iphone(uid, x, y, light, inner):
    w, h, b = PHONE_W, PHONE_H, PHONE_BEZEL
    side = "#BDBDC3" if light else "#2C2C2F"
    buttons = (f'<rect x="{x - 3}" y="{y + 96}" width="4" height="24" rx="1.5" fill="{side}"/>'
               f'<rect x="{x - 3}" y="{y + 134}" width="4" height="44" rx="1.5" fill="{side}"/>'
               f'<rect x="{x + w + 2 * b - 1}" y="{y + 144}" width="4" height="66" rx="1.5" fill="{side}"/>')
    island = f'<rect x="{w / 2 - 36}" y="11" width="72" height="21" rx="10.5" fill="#000"/>'
    return buttons + shell(uid, x, y, w, h, PHONE_R, b, light, inner + island)


def hero(light):
    uid = "hl" if light else "hd"
    W, H, T = 860, 560, 18.0
    pic = {k: data_uri(SRC / f"phone-{k}.jpg") for k in ("now-playing", "lyrics", "home", "radio", "offline")}
    # The watch app's own Now Playing page, drawn by scripts/watch-screenshots.sh around the same song
    # (WATCH_COVER / WATCH_TITLE / WATCH_ARTIST), so the wrist and the phone agree.
    wpic = data_uri(SRC / "watch-now-playing.jpg")
    py = (H - PHONE_H - 2 * PHONE_BEZEL) / 2
    gap, wgap = 36, 56
    x1 = (W - (2 * (PHONE_W + 2 * PHONE_BEZEL) + gap + wgap + WATCH_W + 16 + 7)) / 2
    x2 = x1 + PHONE_W + 2 * PHONE_BEZEL + gap
    xw = x2 + PHONE_W + 2 * PHONE_BEZEL + wgap
    phone_pic = lambda k: picture(pic[k], PHONE_W, PHONE_H)
    body = iphone(uid + "a", x1, py, light, crossfade([phone_pic("now-playing"), phone_pic("lyrics")], T))
    body += iphone(uid + "b", x2, py, light, crossfade([phone_pic(k) for k in ("home", "radio", "offline")], T))
    body += watch(uid + "w", xw, H / 2 - (WATCH_H + 16) / 2, WATCH_W, WATCH_H, light,
                  picture(wpic, WATCH_W, WATCH_H))
    return svg(W, H, body, "Aura on two iPhones and an Apple Watch: Now Playing, synced lyrics, Home, a radio and "
                           "an album ready offline, captured from the app")


# --- cards (portrait, like the app's screens) ----------------------------------------------------------------
CW, CH, M = 240, 400, 20    # card size and its margin


def card(uid, body, title, defs=""):
    panel = (f'<clipPath id="{uid}pc"><rect width="{CW}" height="{CH}" rx="28"/></clipPath>'
             f'<linearGradient id="{uid}pg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#171717"/>'
             f'<stop offset="1" stop-color="{BG2}"/></linearGradient>')
    return svg(CW, CH, f'<g clip-path="url(#{uid}pc)"><rect width="{CW}" height="{CH}" fill="url(#{uid}pg)"/>{body}</g>'
                       f'<rect x=".5" y=".5" width="{CW - 1}" height="{CH - 1}" rx="27.5" fill="none" stroke="{EDGE}"/>',
               title, panel + defs)


def heading(s):
    return text(M, 42, s, 18, weight=700)


PRESETS = [("Flat", [0, 0, 0, 0, 0]), ("Bass Boost", [10, 7, 0, -1, -2]), ("Vocal", [-4, 0, 8, 6, 2]),
           ("Rock", [8, 4, -2, 6, 8]), ("Electronic", [10, 6, 0, 4, 8]), ("Late Night", [6, 4, 2, 0, -2])]


def card_eq():
    x0, x1, y_top, y_bot = 48, CW - M, 104, 324
    xs = [x0 + 14 + i * (x1 - x0 - 28) / 4 for i in range(5)]
    gy = lambda db: y_top + (12 - db) / 24 * (y_bot - y_top)

    def curve(gains):
        p = [(x, gy(g)) for x, g in zip(xs, gains)]
        d = f"M{x0} {p[0][1]:.1f}L{p[0][0]:.1f} {p[0][1]:.1f}"
        for i in range(4):
            a, b, c, e = p[max(0, i - 1)], p[i], p[i + 1], p[min(4, i + 2)]
            d += (f"C{b[0] + (c[0] - a[0]) / 6:.1f} {b[1] + (c[1] - a[1]) / 6:.1f} "
                  f"{c[0] - (e[0] - b[0]) / 6:.1f} {c[1] - (e[1] - b[1]) / 6:.1f} {c[0]:.1f} {c[1]:.1f}")
        return d + f"L{x1} {p[4][1]:.1f}"

    hold, morph = 1.6, 0.7
    T = round(len(PRESETS) * (hold + morph), 3)
    seq = PRESETS + PRESETS[:1]
    times = []
    for i in range(len(PRESETS)):
        times += [(i * (hold + morph), seq[i]), (i * (hold + morph) + hold, seq[i])]
    times.append((T, seq[-1]))
    line = anim("d", [(t, curve(g)) for t, (_, g) in times], T)
    area = anim("d", [(t, curve(g) + f"L{x1} {y_bot + 8}L{x0} {y_bot + 8}Z") for t, (_, g) in times], T)
    g0 = PRESETS[0][1]
    grid = "".join(f'<path d="M{x0} {gy(db):.1f}H{x1}" stroke="#fff" stroke-opacity="{.2 if db == 0 else .07}" '
                   + (' stroke-dasharray="4 4"' if db == 0 else "") + "/>" for db in (-12, -6, 0, 6, 12))
    grid += "".join(text(x0 - 6, gy(db) + 3, lab, 8, op=0.4, anchor="end") for db, lab in ((12, "+12"), (0, "0"), (-12, "−12")))
    grid += "".join(text(x, 350, lab, 8.5, op=0.5, anchor="middle")
                    for x, lab in zip(xs, ["60", "230", "910", "3.6k", "14k"]))
    grid += text(x1, 370, "Hz", 8.5, op=0.35, anchor="end")
    nodes = "".join(f'<circle cx="{x:.1f}" cy="{gy(g0[i]):.1f}" r="5.5" fill="#fff" stroke="{ACCENT}" stroke-width="2.6">'
                    f'{anim("cy", [(t, round(gy(g[i]), 1)) for t, (_, g) in times], T)}</circle>' for i, x in enumerate(xs))
    chips = ""
    for i, (name, _) in enumerate(PRESETS):
        # the chip names the preset the curve is heading for, from the start of its morph
        if i == 0:
            vis = [(0, "visible"), (hold, "hidden"), (T - morph, "visible"), (T, "visible")]
        else:
            on = i * (hold + morph) - morph
            vis = [(0, "hidden"), (on, "visible"), (on + hold + morph, "hidden"), (T, "hidden")]
        vals = ";".join(v for _, v in vis)
        kts = ";".join(kt(t, T) for t, _ in vis)
        cw = width(name, 10.5, True) + 22
        chips += (f'<g visibility="{vis[0][1]}"><animate attributeName="visibility" values="{vals}" keyTimes="{kts}" '
                  f'dur="{T:g}s" calcMode="discrete" repeatCount="indefinite"/>'
                  f'<rect x="{M}" y="58" width="{cw:.1f}" height="23" rx="11.5" fill="{ACCENT}"/>'
                  + text(M + cw / 2, 73.5, name, 10.5, weight=600, anchor="middle") + "</g>")
    defs = (f'<linearGradient id="eqf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{ACCENT}" '
            f'stop-opacity=".32"/><stop offset="1" stop-color="{ACCENT}" stop-opacity="0"/></linearGradient>')
    body = (heading("Equalizer") + chips + grid
            + f'<path d="{curve(g0)}L{x1} {y_bot + 8}L{x0} {y_bot + 8}Z" fill="url(#eqf)">{area}</path>'
            + f'<path d="{curve(g0)}" fill="none" stroke="{ACCENT}" stroke-width="2.6" stroke-linecap="round" '
              f'stroke-linejoin="round">{line}</path>' + nodes)
    return card("eq", body, "A five-band equalizer curve moving between presets", defs)


def mini_cover(uid, x, y, s):
    return cover_genre(uid, x, y, s, SUN[0], SUN[1], ["Midnight", "Signals"], SONG[1],
                       art=f'<circle cx="{s * .6:.1f}" cy="{s * .4:.1f}" r="{s * .27:.1f}" fill="{SUN[1]}"/>')


def demo_lyrics():
    ld, lb, _ = lyrics("ly", LINES, M, 236, 16, 38, 3.2, "#fff", reach=4)
    defs = ld + fade_mask("ly", 0, 76, CW, CH - 76, 56)
    body = (mini_cover("lyc", M, 20, 38) + text(68, 35, SONG[0], 12.5, weight=700) + text(68, 51, SONG[1], 11, op=0.6)
            + icon("quote", CW - M - 8, 39, 18, ACCENT, sw=2) + f'<g mask="url(#lym)">{lb}</g>')
    return card("ly", body, "Synced lyrics lighting up word by word", defs)


def real_cover(f):
    return lambda uid, s: (f'<clipPath id="{uid}"><rect width="{s}" height="{s}" rx="{s * 0.09:.1f}"/></clipPath>'
                           f'<g clip-path="url(#{uid})">{picture(data_uri(SRC / f), s, s)}</g>')


def demo_cover(dark, light, words):
    return lambda uid, s: cover_genre(uid, 0, 0, s, dark, light, words)


MIXES = [(real_cover("cover-radar-1.jpg"), "Radar", "New releases from your artists"),
         (real_cover("cover-afternoon-1.jpg"), "Afternoon", "Mix for this time of day"),
         (real_cover("cover-radar-2.jpg"), "Radar", "New releases from your artists"),
         (real_cover("cover-afternoon-2.jpg"), "Afternoon", "Mix for this time of day")]
DEMO_MIXES = [(demo_cover("#1A1150", "#FF6FB5", ["Late", "Drive"]), "Late Drive", "Mix for this time of day"),
              (demo_cover("#0E1B4D", "#6FF0C4", ["Deep", "Focus"]), "Deep Focus", "Mix for your mood"),
              (demo_cover("#3A0D12", "#FF9F45", ["Golden", "Hour"]), "Golden Hour", "Mix for this time of day"),
              (demo_cover("#10261C", "#C8F25A", ["Slow", "Bloom"]), "Slow Bloom", "Mix for your genres")]


def card_mixes(mixes=MIXES):
    s, gap, y0 = CW - 2 * M, 12, 64
    slot = s + gap
    hold, move = 2.2, 0.7
    n = len(mixes)
    T = round(n * (hold + move), 3)
    items = ""
    for i, (cover, title, sub) in enumerate(mixes + mixes[:1]):
        x = M + i * slot
        items += (f'<g transform="translate({x} {y0})">{cover(f"mxc{i}", s)}</g>'
                  + text(x, y0 + s + 28, title, 14, weight=700) + text(x, y0 + s + 46, sub, 11, op=0.55))
    kf = [(0, (0, 0))]
    for k in range(n):
        kf += [(k * (hold + move) + hold, (-k * slot, 0)), ((k + 1) * (hold + move), (-(k + 1) * slot, 0))]
    dots, dx = "", 14
    d0 = CW / 2 - (n - 1) * dx / 2
    for k in range(n):
        dots += f'<circle cx="{d0 + k * dx:g}" cy="{CH - 34}" r="3.2" fill="#fff" fill-opacity=".22"/>'
    dkf = [(0, (0, 0))]
    for k in range(n):
        nxt = ((k + 1) % n) * dx
        dkf += [(k * (hold + move) + hold, (k * dx, 0)), ((k + 1) * (hold + move), (nxt, 0))]
    dots += f'<circle cx="{d0:g}" cy="{CH - 34}" r="3.2" fill="{ACCENT}">{slide(dkf, T)}</circle>'
    body = (heading("Made For You") + icon("play", CW - M - 6, 36, 15, ACCENT)
            + f'<g>{slide(kf, T)}{items}</g>' + dots)
    return card("mx", body, "Made For You: mix covers sliding past")


# demo releases: invented titles and artists, gradient art (no real names)
RADAR = [("Glass Orchard", "Marine Vale", "Album · 2025", ("#FF6FB5", "#8C5CFF")),
         ("Low Tide Radio", "Holloway Static", "Album · 2025", ("#E9E6E0", "#6B6B6B")),
         ("Every Small Light Left On", "Juniper Coast", "Single · 2025", ("#6FF0C4", "#2F5BFF")),
         ("Northbound Hours", "Odile Fen", "Album · 2025", ("#FF7A1A", "#FF3B30"))]


def bars(x, y, h, color, durs=(0.9, 1.15, 0.8)):
    """The playing glyph: three bars, each bobbing on its own clock."""
    out = ""
    for i, d in enumerate(durs):
        lo, hi = h * 0.3, h
        out += (f'<rect x="{x + i * 4:.1f}" y="{y - lo:.1f}" width="2.6" height="{lo:.1f}" rx="1" fill="{color}">'
                f'<animate attributeName="height" values="{lo:.1f};{hi:.1f};{lo * 1.6:.1f};{hi * .8:.1f};{lo:.1f}" '
                f'dur="{d}s" repeatCount="indefinite"/><animate attributeName="y" values="{y - lo:.1f};{y - hi:.1f};'
                f'{y - lo * 1.6:.1f};{y - hi * .8:.1f};{y - lo:.1f}" dur="{d}s" repeatCount="indefinite"/></rect>')
    return out


def clip_text(s, size, room, bold):
    if width(s, size, bold) <= room:
        return s
    while s and width(s + "…", size, bold) > room:
        s = s[:-1]
    return s.rstrip() + "…"


def art(uid, x, y, s, c1, c2):
    return (f'<linearGradient id="{uid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c1}"/>'
            f'<stop offset="1" stop-color="{c2}"/></linearGradient>'
            f'<rect x="{x}" y="{y}" width="{s}" height="{s}" rx="{s * 0.14:.1f}" fill="url(#{uid})"/>')


def demo_radar():
    T, y0, row, a = 9.0, 70, 56, 42
    body = lockup(M, 16, "New Releases", 190, "#fff") + heading("Radar")
    body += text(CW - M, 42, "This month", 10.5, op=0.5, anchor="end")
    tx = M + a + 12
    for i, (title, artist, meta, (c1, c2)) in enumerate(RADAR):
        y = y0 + i * row
        # all rows show at t = 0 (a still render shows the full list), clear, then arrive one by one
        on = 7.0 + i * 0.4
        op = anim("opacity", [(0, 1), (6.4, 1), (6.9, 0), (on, 0), (on + 0.5, 1), (T, 1)], T)
        mv = slide([(0, (0, 0)), (6.9, (0, 0)), (6.91, (0, 10)), (on, (0, 10)), (on + 0.5, (0, 0)), (T, (0, 0))], T)
        room = CW - M - 26 - tx
        row_svg = (art(f"rd{i}", M, y, a, c1, c2)
                   + text(tx, y + 13, clip_text(title, 12, room, True), 12, weight=700)
                   + text(tx, y + 27, clip_text(artist, 10, room, False), 10, op=0.6)
                   + text(tx, y + 40, meta, 9.5, op=0.4))
        row_svg += (icon("heart", CW - M - 8, y + a / 2, 16, ACCENT, sw=2) if i == 0 else
                    f'<circle cx="{CW - M - 8}" cy="{y + a / 2}" r="10" fill="#fff" fill-opacity=".1"/>'
                    + icon("play", CW - M - 7, y + a / 2, 10, "#fff", op=.8))
        body += f'<g>{op}<g>{mv}{row_svg}</g></g>'
    # the preview playing: a mini player with its 30-second bar
    py, pw = CH - 78, CW - 2 * M
    title, artist, _, (c1, c2) = RADAR[0]
    body += (f'<rect x="{M}" y="{py}" width="{pw}" height="58" rx="14" fill="#fff" fill-opacity=".07"/>'
             + art("rdp", M + 10, py + 10, 38, c1, c2) + bars(M + 58, py + 26, 10, ACCENT)
             + text(M + 74, py + 25, title, 12, weight=700) + text(M + 58, py + 40, "Preview · 0:30", 9.5, op=0.5)
             + f'<rect x="{M + 58}" y="{py + 47}" width="{pw - 72}" height="3" rx="1.5" fill="#fff" fill-opacity=".18"/>'
             + f'<rect x="{M + 58}" y="{py + 47}" width="0" height="3" rx="1.5" fill="{ACCENT}">'
               f'{anim("width", [(0, 0), (T, pw - 72)], T, ease=False)}</rect>')
    return card("rd", body, "Radar: this month's releases appearing, one playing its preview")


DOWNLOADS = [(t, a, c, steps) for (t, a, _, c), steps in zip(RADAR, [
    [(0.3, 0), (1.2, .35), (1.8, .45), (3.0, 1)], [(0.6, 0), (2.0, .3), (3.1, .7), (4.6, 1)],
    [(1.0, 0), (2.6, .2), (4.4, .62), (6.2, 1)], [(1.6, 0), (3.4, .25), (5.6, .7), (7.2, 1)]])]


def demo_offline():
    T, y0, row, r, a = 9.0, 70, 74, 10.5, 46
    circ = 2 * 3.1416 * r
    body = heading("Downloads") + text(CW - M, 42, "On this iPhone", 10.5, op=0.5, anchor="end")
    tx = M + a + 12
    cx = CW - M - 10
    for i, (title, artist, (c1, c2), steps) in enumerate(DOWNLOADS):
        y = y0 + i * row
        cy = y + a / 2
        done = steps[-1][0]
        room = cx - r - 10 - tx
        dash = ([(0, circ)] + [(t, round(circ * (1 - p), 2)) for t, p in steps]
                + [(T - 0.5, 0), (T - 0.5, circ), (T, circ)])
        ring_op = anim("opacity", [(0, 1), (done, 1), (done + 0.2, 0), (T - 0.5, 0), (T - 0.2, 1), (T, 1)], T)
        tick_op = anim("opacity", [(0, 0), (done, 0), (done + 0.2, 1), (T - 0.7, 1), (T - 0.4, 0), (T, 0)], T)
        body += (art(f"dl{i}", M, y, a, c1, c2)
                 + text(tx, y + 15, clip_text(title, 12, room, True), 12, weight=700)
                 + text(tx, y + 30, clip_text(artist, 10, room, False), 10, op=0.6)
                 + text(tx, y + 43, "Album", 9.5, op=0.4)
                 + f'<g>{ring_op}<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#fff" stroke-opacity=".14" '
                   f'stroke-width="2.6"/><circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{ACCENT}" stroke-width="2.6" '
                   f'stroke-linecap="round" stroke-dasharray="{circ:.2f}" stroke-dashoffset="{circ:.2f}" '
                   f'transform="rotate(-90 {cx} {cy})">{anim("stroke-dashoffset", dash, T)}</circle>'
                   f'<rect x="{cx - 3}" y="{cy - 3}" width="6" height="6" rx="1.2" fill="{ACCENT}"/></g>'
                 + f'<g opacity="0">{tick_op}<circle cx="{cx}" cy="{cy}" r="{r + 1.3}" fill="{ACCENT}"/>'
                   + icon("check", cx, cy, 17, "#fff", sw=2.6) + "</g>")
        if i < len(DOWNLOADS) - 1:
            body += f'<path d="M{tx} {y + row - 14}H{CW - M}" stroke="#fff" stroke-opacity=".07"/>'
    return card("dl", body, "Offline: albums downloading, progress rings filling")


TRACKS = [(SONG[0], SONG[1], BLOBS, SUN), ("Paper Lanterns", "Marine Vale",
                                           [(0.2, 0.2, 0.55, 0.3, "#0E1B4D"), (0.85, 0.3, 0.45, 0.28, "#3DCBFF"),
                                            (0.3, 0.8, 0.6, 0.3, "#0B2E24"), (0.9, 0.85, 0.5, 0.25, "#6FF0C4")],
                                           ("#0E1B4D", "#6FF0C4"))]


def carplay_screen(uid, w, h, title, artist, blobs, duo, prog):
    out = backdrop(uid, w, h, blobs, veil=0.35)
    out += f'<rect width="26" height="{h}" fill="#000" fill-opacity=".55"/>' + text(13, 13, "9:41", 6.5, weight=600, anchor="middle")
    for i, c in enumerate(("#3DCBFF", ACCENT, "#34C759")):
        out += f'<rect x="6" y="{26 + i * 19}" width="14" height="14" rx="3.5" fill="{c}"/>'
    out += icon("play", 13, 33 + 19, 7, "#fff")
    out += mini_cover_duo(uid + "c", 36, 14, 60, duo, title)
    out += (text(106, 30, clip_text(title, 10, w - 112, True), 10, weight=700)
            + text(106, 43, clip_text(artist, 8.5, w - 112, False), 8.5, op=0.7))
    out += (f'<rect x="106" y="58" width="{w - 118}" height="3" rx="1.5" fill="#fff" fill-opacity=".25"/>'
            f'<rect x="106" y="58" width="{(w - 118) * prog[0][1]:.1f}" height="3" rx="1.5" fill="#fff">'
            f'{anim("width", [(t, round((w - 118) * p, 1)) for t, p in prog], prog[-1][0], ease=False)}</rect>')
    out += "".join(icon(n, 36 + i * 30 + 15, 95, sz, "#fff") for i, (n, sz) in
                   enumerate((("heart", 13), ("back", 15), ("pause", 18), ("fwd", 15), ("list", 13))))
    return out


def mini_cover_duo(uid, x, y, s, duo, title):
    return cover_genre(uid, x, y, s, duo[0], duo[1], title.split()[:2], "",
                       art=f'<circle cx="{s * .6:.1f}" cy="{s * .38:.1f}" r="{s * .26:.1f}" fill="{duo[1]}"/>')


def demo_devices():
    T, half = 8.0, 4.0
    cw, ch, ww, wh = 180, 112, 92, 113
    groups_cp, groups_w = "", ""
    for i, (title, artist, blobs, duo) in enumerate(TRACKS):
        # crossfade at the change; each track's bar runs while it shows and resets out of sight
        if i == 0:
            op = [(0, 1), (half - 0.4, 1), (half, 0), (T - 0.4, 0), (T, 1)]
            prog = [(0, .08), (half, .36), (half + .01, .08), (T, .08)]
        else:
            op = [(0, 0), (half - 0.4, 0), (half, 1), (T - 0.4, 1), (T, 0)]
            prog = [(0, .08), (half, .08), (T, .36)]
        o = anim("opacity", op, T)
        groups_cp += f'<g opacity="{op[0][1]}">{o}{carplay_screen(f"cp{i}", cw, ch, title, artist, blobs, duo, prog)}</g>'
        groups_w += f'<g opacity="{op[0][1]}">{o}{watch_now_playing(f"wn{i}", ww, wh, title, artist, blobs, prog)}</g>'
    cx = (CW - cw - 12) / 2
    body = shell("cps", cx, 28, cw, ch, 10, 6, False, groups_cp)
    body += text(CW / 2, 178, "CarPlay", 10.5, weight=600, op=0.6, anchor="middle")
    body += watch("wch", (CW - ww - 16) / 2, 216, ww, wh, False, groups_w, band=14)
    body += text(CW / 2, 380, "Apple Watch", 10.5, weight=600, op=0.6, anchor="middle")
    return card("dv", body, "CarPlay and Apple Watch mirroring Now Playing")


# --- real cards: a capture of the app in a window, panning slowly top to bottom and back ----------------------
WIN_Y, WIN_H = 60, 320


def window(uid, name, T=14.0, hold=2.5):
    w = CW - 2 * M
    h = w * aspect(name)
    travel = max(0.0, h - WIN_H)
    move = T / 2 - hold
    pan = slide([(0, (0, 0)), (hold, (0, 0)), (hold + move, (0, -travel)), (2 * hold + move, (0, -travel)),
                 (T, (0, 0))], T) if travel else ""
    return (f'<clipPath id="{uid}w"><rect x="{M}" y="{WIN_Y}" width="{w}" height="{WIN_H}" rx="20"/></clipPath>'
            f'<g clip-path="url(#{uid}w)"><g transform="translate({M} {WIN_Y})"><g>{pan}'
            f'{picture(data_uri(SRC / name), w, h)}</g></g></g>'
            f'<rect x="{M + .5}" y="{WIN_Y + .5}" width="{w - 1}" height="{WIN_H - 1}" rx="19.5" fill="none" '
            f'stroke="#fff" stroke-opacity=".08"/>')


def card_lyrics():
    return card("ly", heading("Lyrics") + icon("quote", CW - M - 8, 36, 18, ACCENT, sw=2) + window("ly", "card-lyrics.jpg"),
                "The lyrics screen of Aura, captured from the app")


def card_radar():
    return card("rd", heading("Radar") + window("rd", "card-radar.jpg"),
                "The Radar in Aura, captured from the app: new releases from your artists")


def card_offline():
    return card("dl", heading("Downloads") + icon("download", CW - M - 8, 36, 18, ACCENT, sw=2.2)
                + window("dl", "card-offline.jpg"), "An album downloaded in Aura, captured from the app")


def card_devices():
    """The watch app's real Now Playing (scripts/watch-screenshots.sh) over the iPhone playing the same song."""
    pw, ph, b = 130, round(130 * aspect("card-now-playing.jpg")), 6
    island = f'<rect x="{pw / 2 - 18}" y="5" width="36" height="10" rx="5" fill="#000"/>'
    body = heading("iPhone and Watch")
    body += shell("dvp", M, 62, pw, ph, 17, b, False, picture(data_uri(SRC / "card-now-playing.jpg"), pw, ph) + island)
    ww, wh = 92, round(92 * 496 / 416)
    body += watch("dvw", CW - M - ww - 23, 62 + ph + 2 * b - wh - 30, ww, wh, False,
                  picture(data_uri(SRC / "watch-now-playing.jpg"), ww, wh), band=16)
    return card("dv", body, "Aura on an Apple Watch and an iPhone playing the same song, both captured from the app")


# --- buttons -------------------------------------------------------------------------------------------------
BUTTONS = {
    "download": ("download", "Download IPA", "Télécharger l’IPA", True),
    "features": ("grid", "Features", "Fonctions", False),
    "builds": ("builds", "Two builds", "Deux versions", False),
    "source": ("code", "Build from source", "Compiler", False),
}


def button(icon_name, label, accent):
    tw = width(label, 14.5, True)
    w, h = round(tw + 60), 40
    bg, fg, edge, ic = (ACCENT, "#fff", ACCENT, "#fff") if accent else (BG, "#F2F2F2", "#333", ACCENT)
    body = (f'<rect x=".5" y=".5" width="{w - 1}" height="{h - 1}" rx="{h / 2 - .5}" fill="{bg}" stroke="{edge}"/>'
            + icon(icon_name, 27, 20, 17, ic, sw=2.2)
            + text(44, 25, label, 14.5, fg, 600, extra=f' textLength="{tw:.0f}" lengthAdjust="spacing"'))
    return svg(w, h, body, label)


def kofi(fr):
    """The tip button: a coral pill lit from above, the cup in a glass disc with its steam
    rising, two lines of type and a chevron — an App Store button more than a badge."""
    top, sub = (("Offrir un café", "Soutenir Aura sur Ko-fi") if fr else ("Buy me a coffee", "Support Aura on Ko-fi"))
    tw = max(width(top, 18, True), width(sub, 13))
    h = 68
    w = round(16 + 44 + 14 + tw + 22 + 12 + 18)
    cx, cy = 16 + 22, h / 2
    steam = "".join(
        f'<path d="M{dx} -9Q{dx + 2.4} -12 {dx} -15Q{dx - 2.4} -18 {dx} -21" stroke-width="2" opacity="0">'
        f'<animate attributeName="opacity" values="0;.95;0" dur="2.6s" begin="{d}s" repeatCount="indefinite"/>'
        f'<animateTransform attributeName="transform" type="translate" values="0 3;0 -3" dur="2.6s" begin="{d}s" '
        f'repeatCount="indefinite"/></path>' for dx, d in ((-5, 0), (1, 1.3)))
    cup = (f'<g transform="translate({cx} {cy + 3})" fill="none" stroke="#fff" stroke-width="2.4" '
           f'stroke-linecap="round" stroke-linejoin="round">{steam}'
           f'<path d="M-10 -6H6V3A7 7 0 0 1 -1 10H-3A7 7 0 0 1 -10 3Z" fill="#fff"/>'
           f'<path d="M6 -3H8.5A3.5 3.5 0 0 1 8.5 4H6"/></g>')
    defs = ('<linearGradient id="kfg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF6F61"/>'
            f'<stop offset="1" stop-color="#D93F3A"/></linearGradient>'
            '<linearGradient id="kfh" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" '
            'stop-opacity=".35"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>')
    tx = 16 + 44 + 14
    chev = (f'<path d="M{w - 30} {h / 2 - 6}l6 6-6 6" fill="none" stroke="#fff" stroke-width="2.4" '
            f'stroke-linecap="round" stroke-linejoin="round" opacity=".85"/>')
    body = (f'<rect width="{w}" height="{h}" rx="{h / 2}" fill="url(#kfg)"/>'
            f'<rect x="1" y="1" width="{w - 2}" height="{h - 2}" rx="{h / 2 - 1}" fill="url(#kfh)"/>'
            f'<rect x=".5" y=".5" width="{w - 1}" height="{h - 1}" rx="{h / 2 - .5}" fill="none" stroke="#fff" '
            f'stroke-opacity=".22"/>'
            f'<circle cx="{cx}" cy="{cy}" r="22" fill="#fff" fill-opacity=".2"/>' + cup
            + text(tx, 31, top, 18, weight=700) + text(tx, 50, sub, 13, weight=500, op=0.88) + chev)
    return svg(w, h, body, f"{top} on Ko-fi", defs)


def main():
    if "--sources" in sys.argv:
        make_sources()
    if "--demo" in sys.argv:
        demo = OUT / "demo"
        demo.mkdir(exist_ok=True)
        files = {"card-eq.svg": card_eq(), "card-lyrics.svg": demo_lyrics(), "card-mixes.svg": card_mixes(DEMO_MIXES),
                 "card-radar.svg": demo_radar(), "card-offline.svg": demo_offline(), "card-devices.svg": demo_devices()}
        for name, body in files.items():
            (demo / name).write_text(body)
            print(f"demo/{name:21} {len(body.encode()) / 1024:7.1f} KB")
        return
    files = {
        "aura-hero.svg": hero(False), "aura-hero-light.svg": hero(True),
        "card-eq.svg": card_eq(), "card-lyrics.svg": card_lyrics(), "card-mixes.svg": card_mixes(),
        "card-radar.svg": card_radar(), "card-offline.svg": card_offline(), "card-devices.svg": card_devices(),
        "btn-tip.svg": kofi(False), "btn-tip-fr.svg": kofi(True),
    }
    for key, (ic, en, fr, accent) in BUTTONS.items():
        files[f"btn-{key}.svg"] = button(ic, en, accent)
        files[f"btn-{key}-fr.svg"] = button(ic, fr, accent)
    for name, body in files.items():
        (OUT / name).write_text(body)
        print(f"{name:26} {len(body.encode()) / 1024:7.1f} KB")


if __name__ == "__main__":
    main()
