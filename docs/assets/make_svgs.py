"""Regenerates the README art in docs/assets/: animated SVGs drawn after Aura's own layouts.

    python3 docs/assets/make_svgs.py

Stdlib only. Every picture is hand-built SVG, animated with SMIL (<animate>, <animateTransform>), so it plays
inside GitHub's <img> sandbox: no scripts, no external CSS, no webfonts. Text uses the system font stack;
the covers' block letters are that stack in its heaviest weight, squeezed with textLength the way Archivo
Extra Condensed sits on the app's covers.

Proportions come from the app:
  - Now Playing (Views/NowPlayingView.swift): 30 pt side padding, the cover the full column, title2 bold,
    artist at 70 % white, a capsule progress bar at 22 % white, the transport 36 pt apart, repeat in the accent.
  - Lyrics: 30 pt bold, left-aligned; unsung words at 35 %; other lines dimmer, smaller and blurred.
  - Covers (Components/Covers/): margin 0.06 s, column 0.88 s, lockup ▶ + label at 0.042 s, mix title band
    with a cap height up to 0.15 s, artist strip at 0.032 s, genre words up to 0.3 s, the band palette.
  - Equalizer (Components/EqualizerView.swift, Models.swift): five bands at ±12 dB, Catmull-Rom curve
    run flat to both edges, the real preset gains.

Song and artist names in Now Playing, the lyrics and the devices are made up. The Radar and Downloads cards
use the freely licensed releases from the Navidrome demo library that the website also shows.

Writes aura-hero.svg, aura-hero-light.svg, card-*.svg and btn-*.svg (plus -fr buttons) and prints sizes.
"""
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


def lum(hex_):
    r, g, b = (int(hex_[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.299 * r + 0.587 * g + 0.114 * b


def ink(hex_):
    return "#000" if lum(hex_) > 0.55 else "#fff"


def mix(a, b, t):
    ca, cb = ([int(h[i:i + 2], 16) for i in (1, 3, 5)] for h in (a, b))
    return "#" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(ca, cb))


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


def strip(x, bottom, line, s, fg, bg):
    """The artists on a strip at 0.032 s (bottom = its lower edge). Returns (svg, height)."""
    cap = s * 0.032 * CAP
    h = cap + 2 * s * 0.017
    t, w = cap_text(x + s * 0.02, bottom - h + s * 0.017, line, cap, fg, 1.08, 700, s * 0.002)
    return f'<rect x="{x:.2f}" y="{bottom - h:.2f}" width="{w + s * 0.04:.2f}" height="{h:.2f}" fill="{bg}"/>' + t, h


def artists_line(names, s, room):
    for n in range(min(3, len(names)), 0, -1):
        line = " · ".join(names[:n]).upper()
        if width(line, s * 0.032, True) * 1.08 <= room:
            return line
    return None


def framed(uid, x, y, s, body, r=None):
    r = s * 0.07 if r is None else r
    return (f'<clipPath id="{uid}"><rect width="{s:g}" height="{s:g}" rx="{r:.1f}"/></clipPath>'
            f'<g transform="translate({x:g} {y:g})"><g clip-path="url(#{uid})">{body}</g></g>')


def title_band(s, title, column, max_cap, fg, bg, bottom):
    """A black band bleeding off the left edge that ends with the word (MixCoverTemplate)."""
    m = s * 0.06
    cap = fit(title, column, max_cap)
    h = cap + 2 * s * 0.032
    t, w = cap_text(m, bottom - h + s * 0.032, title, cap, fg)
    return f'<rect y="{bottom - h:.2f}" width="{m + w + s * 0.035:.2f}" height="{h:.2f}" fill="{bg}"/>' + t, h


def cover_mix(uid, x, y, s, band, kicker, title, artists):
    m, col = s * 0.06, s * 0.88
    body = f'<rect width="{s:g}" height="{s:g}" fill="{band}"/>' + lockup(m, m, kicker, s, ink(band))
    line = artists_line(artists, s, col - s * 0.04)
    bottom = s - m
    if line:
        st, h = strip(m, bottom, line, s, "#fff", "#000")
        body += st
        bottom -= h
    body += title_band(s, title.upper(), col, s * 0.15, band, "#000", bottom)[0]
    return framed(uid, x, y, s, body)


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


def cover_year(uid, x, y, s, period, kicker="Wrapped"):
    m, col = s * 0.06, s * 0.88
    cap = fit(period, col, s * 0.42)
    top = m + s * 0.042 * CAP * 1.3 + s * 0.035
    body = (f'<linearGradient id="{uid}g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FF6B2C"/>'
            f'<stop offset=".5" stop-color="#C2185B"/><stop offset="1" stop-color="#311B92"/></linearGradient>'
            f'<rect width="{s:g}" height="{s:g}" fill="url(#{uid}g)"/>' + cap_text(m, top, period, cap, "#fff")[0]
            + f'<g transform="translate({s * 0.14:.1f} {top + cap * 0.5:.1f}) scale({s * 0.0072:.4f})" '
              f'fill="#24104F">{FIGURE}</g>' + lockup(m, m, kicker, s, "#fff", "#fff"))
    return framed(uid, x, y, s, body)


def cover_radio(uid, x, y, s, field, name, artists):
    m, col = s * 0.06, s * 0.88
    hx, hy = s * 0.5, s * 0.4
    tone = mix(field, "#000000", 0.16)
    k = ink(field)
    rings = "".join(
        f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="{s * (0.40 + i * 0.12):.1f}" fill="none" stroke="{k}" '
        f'stroke-opacity="{0.16 * min(1, max(0, (0.95 - (0.40 + i * 0.12)) / 0.25)):.3f}" stroke-width="{s * 0.005:.2f}"/>'
        for i in range(5) if (0.40 + i * 0.12) * s > s * 0.31)

    def disc(cx, cy, side, tint, rim=False):
        d = s * side
        out = f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{d / 2 + (s * 0.014 if rim else 0):.1f}" fill="{field}"/>' if rim else ""
        out += (f'<clipPath id="{uid}d{side}{int(cx)}"><circle cx="{cx:.1f}" cy="{cy:.1f}" r="{d / 2:.1f}"/></clipPath>'
                f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{d / 2:.1f}" fill="{tone}"/>'
                f'<g clip-path="url(#{uid}d{side}{int(cx)})"><g transform="translate({cx - d / 2:.1f} {cy - d / 2 + d * 0.08:.1f}) '
                f'scale({d / 100:.4f})" fill="{tint}">{FIGURE}</g></g>')
        return out

    body = (f'<radialGradient id="{uid}r" cx=".5" cy=".4" r=".9"><stop offset=".42" stop-color="{field}"/>'
            f'<stop offset="1" stop-color="{mix(field, "#000000", 0.3)}"/></radialGradient>'
            f'<rect width="{s:g}" height="{s:g}" fill="url(#{uid}r)"/>{rings}'
            + disc(s * 0.11, s * 0.49, 0.36, mix(field, "#FFFFFF", 0.45))
            + disc(s * 0.88, s * 0.25, 0.36, mix(field, "#FFFFFF", 0.45))
            + disc(hx, hy, 0.62, "#F4EFEA", rim=True)
            + lockup(m, m, "Radio", s, k))
    bottom = s - m
    line = artists_line(artists, s, col - s * 0.04)
    if line:
        st, h = strip(m, bottom, line, s, "#000", "#fff")
        body += st
        bottom -= h
    body += title_band(s, name.upper(), col - s * 0.035, s * 0.14, field, "#000", bottom)[0]
    return framed(uid, x, y, s, body)


def sunset(uid, s, dark, light):
    """The hero's album art: a striped sun over water, in the genre covers' duotone."""
    cx, cy, r = s * 0.6, s * 0.42, s * 0.27
    bars = "".join(f'<rect x="0" y="{cy + i * s * 0.045 - s * 0.01:.1f}" width="{s:g}" height="{s * (0.008 + i * 0.006):.1f}" '
                   f'fill="{dark}"/>' for i in range(1, 6))
    waves = "".join(f'<path d="M{s * 0.12:.1f} {cy + r + s * (0.05 + i * 0.05):.1f}h{s * (0.76 - i * 0.12):.1f}" '
                    f'transform="translate({s * i * 0.06:.1f} 0)" stroke="{light}" stroke-opacity="{0.5 - i * 0.1:.1f}" '
                    f'stroke-width="{s * 0.012:.1f}" stroke-linecap="round"/>' for i in range(4))
    return (f'<linearGradient id="{uid}sun" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{light}"/>'
            f'<stop offset="1" stop-color="{ACCENT}"/></linearGradient>'
            f'<linearGradient id="{uid}sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2B0A3D"/>'
            f'<stop offset="1" stop-color="{dark}"/></linearGradient>'
            f'<rect width="{s:g}" height="{s:g}" fill="url(#{uid}sky)"/>'
            f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="url(#{uid}sun)"/>{bars}{waves}')


# --- lyrics (word by word, the line in focus sharp, the others dimmed and blurred) ---------------------------
OPACITY = {0: 1, 1: 0.42, 2: 0.16}
BLUR = {0: 0, 1: 1.1, 2: 2.2}
UNSUNG = 0.35


def lyrics(uid, lines, x, yc, size, lh, step, fill, move=0.55, lead=0.35):
    """Scrolls `lines` round and round, one per `step` seconds; returns (defs, body, total)."""
    n = len(lines)
    total = round(n * step, 3)
    ts, ss = [0.0], [0]
    for k in range(1, n + 1):
        ts += [k * step - move, k * step]
        ss += [k - 1, k]
    defs, body = "", ""
    for j in range(-2, n + 3):
        ops = [OPACITY.get(abs(j - s), 0) for s in ss]
        if not any(ops):
            continue
        blur = [BLUR.get(abs(j - s), 3) for s in ss]
        defs += (f'<filter id="{uid}b{j + 2}" x="-5%" y="-60%" width="110%" height="220%"><feGaussianBlur '
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
        body += (f'<g filter="url(#{uid}b{j + 2})" opacity="{ops[0]}">{anim("opacity", list(zip(ts, ops)), total)}'
                 f'<text x="{x:g}" y="{yc + j * lh + size * 0.36:.1f}" font-family="{FONT}" font-size="{size:g}" '
                 f'font-weight="700" fill="{fill}" letter-spacing="-.2">{spans.rstrip()}</text></g>')
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


def phone_now_playing(uid, w, h):
    k = w / 393  # points → pixels
    pad = 30 * k
    s = w - 2 * pad
    cy = 66
    out = backdrop(uid, w, h, BLOBS)
    out += text(26, 21, "9:41", 11, weight=600)
    out += f'<rect x="{w / 2 - 40}" y="9" width="80" height="22" rx="11" fill="#000"/>'
    out += "".join(f'<rect x="{w - 62 + i * 4}" y="{17 - i * 1.6:.1f}" width="2.6" height="{3 + i * 1.6:.1f}" rx=".8" fill="#fff"/>'
                   for i in range(4))
    out += (f'<rect x="{w - 40}" y="12.5" width="19" height="9" rx="2.6" fill="none" stroke="#fff" stroke-opacity=".5"/>'
            f'<rect x="{w - 38.5}" y="14" width="13" height="6" rx="1.4" fill="#fff"/>')
    out += f'<rect x="{w / 2 - 18}" y="40" width="36" height="4.5" rx="2.25" fill="#fff" fill-opacity=".35"/>'
    art = sunset(uid + "c", s, *SUN)
    m, col = s * 0.06, s * 0.88
    caps = [fit(wd.upper(), col, s * 0.3) for wd in ("Midnight", "Signals")]
    top = s - m - sum(caps) - s * 0.03
    words = ""
    for wd, c in zip(("MIDNIGHT", "SIGNALS"), caps):
        words += cap_text(m, top, wd, c, "#fff")[0]
        top += c + s * 0.03
    cover = (art + f'<linearGradient id="{uid}cv" x1="0" y1="0" x2="0" y2="1"><stop offset=".45" stop-color="{SUN[0]}" '
             f'stop-opacity="0"/><stop offset=".95" stop-color="{SUN[0]}" stop-opacity=".9"/></linearGradient>'
             f'<rect width="{s:g}" height="{s:g}" fill="url(#{uid}cv)"/>' + lockup(m, m, SONG[1], s, "#fff") + words)
    out += (f'<rect x="{pad:.1f}" y="{cy + 6}" width="{s:.1f}" height="{s:.1f}" rx="10" fill="#000" fill-opacity=".35" '
            f'filter="url(#{uid}bd)"/>' + framed(uid + "cover", pad, cy, s, cover, r=7))
    ty = cy + s + 32
    out += text(w / 2, ty, SONG[0], 16, weight=700, anchor="middle")
    out += text(w / 2, ty + 19, SONG[1], 12.5, op=0.7, anchor="middle")
    out += text(pad, ty + 44, "2024 · Electronic", 8.5, op=0.5)
    out += icon("heart", w - pad - 30, ty + 41, 15, sw=2) + icon("dots", w - pad - 7, ty + 41, 15)
    by = ty + 56
    out += (f'<rect x="{pad:.1f}" y="{by}" width="{s:.1f}" height="4" rx="2" fill="#fff" fill-opacity=".22"/>'
            f'<rect x="{pad:.1f}" y="{by}" width="{s * 0.38:.1f}" height="4" rx="2" fill="#fff"/>')
    out += text(pad, by + 16, "1:31", 8, op=0.5) + text(w - pad, by + 16, "-2:16", 8, op=0.5, anchor="end")
    ry = by + 50
    gap = 36 * k + 24
    for i, (name, size, col_, op) in enumerate((("shuffle", 17, "#fff", .7), ("back", 25, "#fff", 1),
                                                ("pause", 38, "#fff", 1), ("fwd", 25, "#fff", 1),
                                                ("repeat", 17, ACCENT, 1))):
        out += icon(name, w / 2 + (i - 2) * gap, ry, size, col_, sw=2.2, op=op)
    out += "".join(icon(n, w / 2 + (i - 1) * 74, h - 46, 17, sw=1.9, op=.75)
                   for i, n in enumerate(("quote", "airplay", "list")))
    out += f'<rect x="{w / 2 - 50}" y="{h - 10}" width="100" height="4" rx="2" fill="#fff" fill-opacity=".8"/>'
    return out


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


# --- hero ----------------------------------------------------------------------------------------------------
def hero(light):
    uid = "hl" if light else "hd"
    W, H = 960, 600
    fg = "#121212" if light else "#FFFFFF"
    glow_op = 0.16 if light else 0.4
    ld, lb, T = lyrics(uid + "l", LINES, 404, 300, 27, 50, 3.4, fg)
    defs = (f'<filter id="{uid}glow" x="-80%" y="-80%" width="260%" height="260%"><feGaussianBlur stdDeviation="50"/></filter>'
            + ld + fade_mask(uid, 380, 150, 380, 300, 70))
    glow = (f'<g filter="url(#{uid}glow)" opacity="{glow_op}">'
            f'<ellipse cx="300" cy="300" rx="120" ry="120" fill="{ACCENT}">'
            f'{anim("cx", [(0, 290), (T / 2, 340), (T, 290)], T)}</ellipse>'
            f'<ellipse cx="720" cy="300" rx="110" ry="110" fill="#8C5CFF">'
            f'{anim("cy", [(0, 320), (T / 2, 280), (T, 320)], T)}</ellipse></g>')
    pw, ph = 252, 546
    phone = shell(uid + "p", 76, 17, pw, ph, 40, 10, light, phone_now_playing(uid + "p", pw, ph))
    side = "#BDBDC3" if light else "#2C2C2F"
    phone = (f'<rect x="73" y="140" width="4" height="26" rx="1.5" fill="{side}"/><rect x="73" y="180" width="4" '
             f'height="46" rx="1.5" fill="{side}"/><rect x="{76 + pw + 19}" y="190" width="4" height="70" rx="1.5" '
             f'fill="{side}"/>' + phone)
    caption = (f'<g opacity=".55">' + lockup(404, 140, "Synced lyrics", 260, fg, ACCENT) + "</g>")
    ww, wh = 150, 182
    wt = watch(uid + "w", 788, 300 - wh / 2 - 8, ww, wh, light, watch_now_playing(uid + "w", ww, wh, *SONG))
    body = glow + phone + caption + f'<g mask="url(#{uid}m)">{lb}</g>' + wt
    return svg(W, H, body, "Aura on iPhone and Apple Watch: Now Playing with an editorial cover, and synced lyrics "
                           "lighting up word by word", defs)


# --- cards ---------------------------------------------------------------------------------------------------
CW, CH = 320, 200


def card(uid, body, title, defs=""):
    panel = (f'<clipPath id="{uid}pc"><rect width="{CW}" height="{CH}" rx="18"/></clipPath>'
             f'<linearGradient id="{uid}pg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#171717"/>'
             f'<stop offset="1" stop-color="{BG2}"/></linearGradient>')
    return svg(CW, CH, f'<g clip-path="url(#{uid}pc)"><rect width="{CW}" height="{CH}" fill="url(#{uid}pg)"/>{body}</g>'
                       f'<rect x=".5" y=".5" width="{CW - 1}" height="{CH - 1}" rx="17.5" fill="none" stroke="{EDGE}"/>',
               title, panel + defs)


PRESETS = [("Flat", [0, 0, 0, 0, 0]), ("Bass Boost", [10, 7, 0, -1, -2]), ("Vocal", [-4, 0, 8, 6, 2]),
           ("Rock", [8, 4, -2, 6, 8]), ("Electronic", [10, 6, 0, 4, 8]), ("Late Night", [6, 4, 2, 0, -2])]


def card_eq():
    x0, x1, y_top, y_bot = 46, 300, 54, 154
    xs = [x0 + 20 + i * (x1 - x0 - 40) / 4 for i in range(5)]
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
    grid += "".join(text(x, 178, f"{lab} Hz", 8.5, op=0.5, anchor="middle")
                    for x, lab in zip(xs, ["60", "230", "910", "3.6k", "14k"]))
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
        cw = width(name, 10, True) + 20
        chips += (f'<g visibility="{vis[0][1]}"><animate attributeName="visibility" values="{vals}" keyTimes="{kts}" '
                  f'dur="{T:g}s" calcMode="discrete" repeatCount="indefinite"/>'
                  f'<rect x="{300 - cw:.1f}" y="16" width="{cw:.1f}" height="21" rx="10.5" fill="{ACCENT}"/>'
                  + text(300 - cw / 2, 30, name, 10, weight=600, anchor="middle") + "</g>")
    defs = (f'<linearGradient id="eqf" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{ACCENT}" '
            f'stop-opacity=".32"/><stop offset="1" stop-color="{ACCENT}" stop-opacity="0"/></linearGradient>')
    body = (text(20, 31, "Equalizer", 15, weight=700) + chips + grid
            + f'<path d="{curve(g0)}L{x1} {y_bot + 8}L{x0} {y_bot + 8}Z" fill="url(#eqf)">{area}</path>'
            + f'<path d="{curve(g0)}" fill="none" stroke="{ACCENT}" stroke-width="2.6" stroke-linecap="round" '
              f'stroke-linejoin="round">{line}</path>' + nodes)
    return card("eq", body, "A five-band equalizer curve moving between presets", defs)


def mini_cover(uid, x, y, s):
    return cover_genre(uid, x, y, s, SUN[0], SUN[1], ["Midnight", "Signals"], SONG[1],
                       art=f'<circle cx="{s * .6:.1f}" cy="{s * .4:.1f}" r="{s * .27:.1f}" fill="{SUN[1]}"/>')


def card_lyrics():
    ld, lb, _ = lyrics("ly", LINES, 20, 122, 19.5, 33, 3.2, "#fff")
    defs = ld + fade_mask("ly", 0, 58, CW, 142, 34)
    body = (mini_cover("lyc", 20, 16, 32) + text(62, 29, SONG[0], 12, weight=700) + text(62, 43, SONG[1], 10.5, op=0.6)
            + icon("quote", 292, 32, 17, ACCENT, sw=2) + f'<g mask="url(#lym)">{lb}</g>')
    return card("ly", body, "Synced lyrics lighting up word by word", defs)


MIXES = [
    ("mix", "#F7E11B", "New Releases", "Radar", ["Natasha Beller", "Nine Inch Nails"], "Radar", "New releases"),
    ("mix", "#FF7A1A", "Mix", "Evening", ["Natasha Beller", "Brad Sucks"], "Evening Mix", "Wind down"),
    ("genre", ("#1A1150", "#FF6FB5"), "Mix", ["Soul", "Jazz"], None, "Soul Jazz Mix", "Your favourites"),
    ("radio", "#3DCBFF", None, "Brad Sucks", ["Nine Inch Nails", "Natasha Beller"], "Brad Sucks Radio", "Similar artists"),
    ("mix", "#6FF0C4", "Mix", "Chill", ["The Polish Ambassador"], "Chill Mix", "Calm, laid-back"),
    ("year", None, "Wrapped", "2025", None, "Your 2025 Wrapped", "Your year"),
]


def any_cover(uid, x, y, s, spec):
    kind, color, kicker, title, artists = spec[:5]
    if kind == "mix":
        return cover_mix(uid, x, y, s, color, kicker, title, artists)
    if kind == "genre":
        return cover_genre(uid, x, y, s, color[0], color[1], title, kicker)
    if kind == "radio":
        return cover_radio(uid, x, y, s, color, title, artists)
    return cover_year(uid, x, y, s, title, kicker)


def card_mixes():
    s, gap, x0, y0 = 104, 14, 20, 46
    slot = s + gap
    hold, move = 1.9, 0.7
    n = len(MIXES)
    T = round(n * (hold + move), 3)
    items = ""
    for i, spec in enumerate(MIXES + MIXES[:3]):
        x = x0 + i * slot
        items += (any_cover(f"mx{i}", x, y0, s, spec) + text(x, y0 + s + 17, spec[5], 11, weight=700)
                  + text(x, y0 + s + 31, spec[6], 9.5, op=0.55))
    kf = [(0, (0, 0))]
    for k in range(n):
        kf += [(k * (hold + move) + hold, (-k * slot, 0)), ((k + 1) * (hold + move), (-(k + 1) * slot, 0))]
    body = (text(20, 31, "Made For You", 15, weight=700) + icon("play", 296, 26, 14, ACCENT)
            + f'<g>{slide(kf, T)}{items}</g>')
    return card("mx", body, "Made For You: Aura's editorial mix covers in rotation")


RADAR = [("Fairytale", "Natasha Beller · Album · 2018", ("#FF6FB5", "#8C5CFF")),
         ("The Slip", "Nine Inch Nails · Album · 2008", ("#E9E6E0", "#6B6B6B")),
         ("Pushing Through The Pavement", "The Polish Ambassador · Album · 2014", ("#6FF0C4", "#2F5BFF")),
         ("I Don’t Know What I’m Doing", "Brad Sucks · Album · 2003", ("#FF7A1A", "#FF3B30"))]


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


def card_radar():
    T, y0, row = 9.0, 54, 35
    defs, body = "", lockup(20, 16, "New Releases", 190, "#fff") + text(20, 42, "Radar", 17, weight=700)
    body += text(300, 42, "This month", 10, op=0.5, anchor="end")
    for i, (title, meta, (c1, c2)) in enumerate(RADAR):
        y = y0 + i * row
        # all rows show at t = 0 (a still render shows the full list), clear, then arrive one by one
        on = 7.0 + i * 0.4
        op = anim("opacity", [(0, 1), (6.4, 1), (6.9, 0), (on, 0), (on + 0.5, 1), (T, 1)], T)
        mv = slide([(0, (0, 0)), (6.9, (0, 0)), (6.91, (0, 10)), (on, (0, 10)), (on + 0.5, (0, 0)), (T, (0, 0))], T)
        defs += (f'<linearGradient id="rd{i}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c1}"/>'
                 f'<stop offset="1" stop-color="{c2}"/></linearGradient>')
        tx = 60 + (16 if i == 0 else 0)
        row_svg = (f'<rect x="20" y="{y}" width="30" height="30" rx="5" fill="url(#rd{i})"/>'
                   + (bars(60, y + 13.5, 10, ACCENT) if i == 0 else "")
                   + text(tx, y + 12.5, clip_text(title, 11.5, 230 - tx, True), 11.5, weight=700)
                   + text(60, y + 26, meta, 9.5, op=0.55))
        row_svg += (icon("heart", 296, y + 15, 15, ACCENT, sw=2) if i == 0 else
                    f'<circle cx="296" cy="{y + 15}" r="10" fill="#fff" fill-opacity=".1"/>' + icon("play", 297, y + 15, 10, "#fff", op=.8))
        body += f'<g>{op}<g>{mv}{row_svg}</g></g>'
    return card("rd", body, "Radar: this month's releases appearing, one playing its preview", defs)


DOWNLOADS = [("The Slip", "Nine Inch Nails", ("#E9E6E0", "#6B6B6B"), [(0.3, 0), (1.2, .35), (1.8, .45), (3.0, 1)]),
             ("Fairytale", "Natasha Beller", ("#FF6FB5", "#8C5CFF"), [(0.6, 0), (2.0, .3), (3.1, .7), (4.6, 1)]),
             ("Pushing Through The Pavement", "The Polish Ambassador", ("#6FF0C4", "#2F5BFF"),
              [(1.0, 0), (2.6, .2), (4.4, .62), (6.2, 1)])]


def card_offline():
    T, y0, row, r = 9.0, 50, 48, 10.5
    circ = 2 * 3.1416 * r
    defs = ""
    body = text(20, 31, "Downloads", 15, weight=700) + text(300, 31, "On this iPhone", 10, op=0.5, anchor="end")
    for i, (title, artist, (c1, c2), steps) in enumerate(DOWNLOADS):
        y = y0 + i * row
        cx, cy = 292, y + 19
        done = steps[-1][0]
        defs += (f'<linearGradient id="dl{i}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{c1}"/>'
                 f'<stop offset="1" stop-color="{c2}"/></linearGradient>')
        dash = ([(0, circ)] + [(t, round(circ * (1 - p), 2)) for t, p in steps]
                + [(T - 0.5, 0), (T - 0.5, circ), (T, circ)])
        ring_op = anim("opacity", [(0, 1), (done, 1), (done + 0.2, 0), (T - 0.5, 0), (T - 0.2, 1), (T, 1)], T)
        tick_op = anim("opacity", [(0, 0), (done, 0), (done + 0.2, 1), (T - 0.7, 1), (T - 0.4, 0), (T, 0)], T)
        body += (f'<rect x="20" y="{y}" width="38" height="38" rx="6" fill="url(#dl{i})"/>'
                 + text(70, y + 16, clip_text(title, 12, 190, True), 12, weight=700)
                 + text(70, y + 31, f"{artist} · Album", 10, op=0.55)
                 + f'<g>{ring_op}<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="#fff" stroke-opacity=".14" '
                   f'stroke-width="2.6"/><circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{ACCENT}" stroke-width="2.6" '
                   f'stroke-linecap="round" stroke-dasharray="{circ:.2f}" stroke-dashoffset="{circ:.2f}" '
                   f'transform="rotate(-90 {cx} {cy})">{anim("stroke-dashoffset", dash, T)}</circle>'
                   f'<rect x="{cx - 3}" y="{cy - 3}" width="6" height="6" rx="1.2" fill="{ACCENT}"/></g>'
                 + f'<g opacity="0">{tick_op}<circle cx="{cx}" cy="{cy}" r="{r + 1.3}" fill="{ACCENT}"/>'
                   + icon("check", cx, cy, 17, "#fff", sw=2.6) + "</g>")
        if i < 2:
            body += f'<path d="M70 {y + row - 5}H300" stroke="#fff" stroke-opacity=".07"/>'
    return card("dl", body, "Offline: albums downloading, progress rings filling", defs)


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


def card_devices():
    T, half = 8.0, 4.0
    cw, ch, ww, wh = 180, 112, 76, 94
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
    body = shell("cps", 14, 36, cw, ch, 10, 6, False, groups_cp)
    body += watch("wch", 218, 99 - wh / 2 - 8, ww, wh, False, groups_w, band=14)
    body += text(14 + cw / 2 + 6, 182, "CarPlay", 10.5, weight=600, op=0.6, anchor="middle")
    body += text(218 + (ww + 16) / 2, 182, "Apple Watch", 10.5, weight=600, op=0.6, anchor="middle")
    return card("dv", body, "CarPlay and Apple Watch mirroring Now Playing")


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


def main():
    files = {
        "aura-hero.svg": hero(False), "aura-hero-light.svg": hero(True),
        "card-eq.svg": card_eq(), "card-lyrics.svg": card_lyrics(), "card-mixes.svg": card_mixes(),
        "card-radar.svg": card_radar(), "card-offline.svg": card_offline(), "card-devices.svg": card_devices(),
    }
    for key, (ic, en, fr, accent) in BUTTONS.items():
        files[f"btn-{key}.svg"] = button(ic, en, accent)
        files[f"btn-{key}-fr.svg"] = button(ic, fr, accent)
    for name, body in files.items():
        (OUT / name).write_text(body)
        print(f"{name:26} {len(body.encode()) / 1024:5.1f} KB")


if __name__ == "__main__":
    main()
