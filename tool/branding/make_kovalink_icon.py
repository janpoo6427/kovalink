#!/usr/bin/env python3
"""KovaLink app icon generator.

Builds every KovaLink launcher icon from the approved kovapilot "K" symbol
(branding/kovalink_icon/source/, copied unchanged from the kovapilot brand
package). The symbol itself is never redrawn: it is only scaled, centred and
placed on the app's dark background.

Usage (needs Pillow; cairosvg optional, only for the SVG self-check):
    python3 tool/branding/make_kovalink_icon.py            # app resources + branding/
    python3 tool/branding/make_kovalink_icon.py --pack DIR  # + download pack folder
    python3 tool/branding/make_kovalink_icon.py --pack DIR --zip OUT.zip

Writes:
  android/app/src/main/res/mipmap-*/ic_launcher*.png
  android/app/src/main/res/mipmap-anydpi-v26/ic_launcher*.xml
  android/app/src/main/res/values/ic_launcher_background.xml
  ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png (names from Contents.json)
  branding/kovalink_icon/* (masters, SVG, variant, preview)
"""
from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import zipfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "branding" / "kovalink_icon"
SRC_PNG = BRAND / "source" / "kovapilot_icon_white_1024w.png"
SRC_SVG = BRAND / "source" / "kovapilot_icon_white.svg"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
IOS = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"

# Colours ------------------------------------------------------------------
BG = (0x07, 0x0B, 0x10)        # KovaLink dark scaffold background (lib/src/app/kovalink_app.dart)
FG = (0xFF, 0xFF, 0xFF)        # brand white
ACCENT = (0x58, 0xF2, 0xC2)    # KovaLink accent (variant only)
BG_HEX = "#%02X%02X%02X" % BG
ACCENT_HEX = "#%02X%02X%02X" % ACCENT

# Geometry -----------------------------------------------------------------
# Symbol bounding-box width as a share of the *visible* icon width.
# (full canvas for iOS / Play / master, 72dp of the 108dp adaptive canvas.)
SYMBOL_W = 0.60
# Shift toward the optical centre: fraction of (mass centroid - bbox centre)
# that is removed. 0 = pure bbox centring, 1 = pure centroid centring.
OPTICAL_K = 0.5
SS = 4  # supersampling factor for every render

ANDROID_DPI = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
LEGACY_DP = 48       # legacy launcher icon canvas
LEGACY_BODY_DP = 44  # visible body inside the 48dp canvas (2dp gutter)
LEGACY_RADIUS_DP = 9  # corner radius of the legacy rounded square
ADAPTIVE_DP = 108
ADAPTIVE_VISIBLE_DP = 72
ADAPTIVE_SAFE_DP = 66


# Symbol -------------------------------------------------------------------
_MASTER = None


def master_alpha() -> Image.Image:
    """Approved symbol alpha, cropped to its bbox, at 4x of the 1024w PNG.

    The 1024w brand PNG is an upscale of a 290px original, so its long
    diagonals carry stair steps. A blur + gentle level curve (contour kept at
    the 50% level) removes them; checked: the 50% outline moves by at most
    ~1px at 1024w (0.4% of the area), bbox unchanged.
    """
    global _MASTER
    if _MASTER is None:
        a = Image.open(SRC_PNG).convert("RGBA").getchannel("A")
        a = a.crop(a.getbbox())
        w, h = a.size
        big = a.resize((w * 4, h * 4), Image.BICUBIC)
        big = big.filter(ImageFilter.GaussianBlur(2.5 * 4))
        lo, hi = 40, 215
        lut = []
        for v in range(256):
            t = min(1.0, max(0.0, (v - lo) / (hi - lo)))
            lut.append(round(255 * t * t * (3 - 2 * t)))
        _MASTER = big.point(lut)
    return _MASTER


_OFFSET = None


def optical_offset() -> tuple[float, float]:
    """Offset (in symbol-bbox units) to add to the bbox centre."""
    global _OFFSET
    if _OFFSET is not None:
        return _OFFSET
    a = master_alpha().reduce(8)
    w, h = a.size
    data = a.load()
    sx = sy = s = 0.0
    for y in range(h):
        for x in range(w):
            v = data[x, y]
            if v:
                sx += v * x
                sy += v * y
                s += v
    cx, cy = sx / s / w, sy / s / h  # 0..1
    _OFFSET = (-(cx - 0.5) * OPTICAL_K, -(cy - 0.5) * OPTICAL_K)
    return _OFFSET


def symbol_layer(size: int, visible: float, colour, *, dot: bool = False) -> Image.Image:
    """RGBA canvas size x size with the symbol centred; symbol width =
    SYMBOL_W * visible (both in output px)."""
    S = size * SS
    m = master_alpha()
    sw = SYMBOL_W * visible * SS
    sh = sw * m.size[1] / m.size[0]
    ox, oy = optical_offset()
    x0 = S / 2 - sw / 2 + ox * sw
    y0 = S / 2 - sh / 2 + oy * sh
    alpha = Image.new("L", (S, S), 0)
    sym = m.resize((max(1, round(sw)), max(1, round(sh))), Image.LANCZOS)
    alpha.paste(sym, (round(x0), round(y0)))
    layer = Image.new("RGBA", (S, S), colour + (0,))
    layer.putalpha(alpha)
    if dot:
        # Variant only: small accent "link" dot in the empty lower-right
        # corner of the symbol bbox (bottom aligned with the lower leg).
        d = 0.15 * sh
        cx = x0 + sw - d / 2
        cy = y0 + sh - d / 2
        dl = Image.new("L", (S, S), 0)
        ImageDraw.Draw(dl).ellipse((cx - d / 2, cy - d / 2, cx + d / 2, cy + d / 2), fill=255)
        dot_layer = Image.new("RGBA", (S, S), ACCENT + (0,))
        dot_layer.putalpha(dl)
        layer = Image.alpha_composite(layer, dot_layer)
    return layer.resize((size, size), Image.LANCZOS) if SS != 1 else layer


def dot_geometry(visible: float):
    """Dot centre/diameter in the same units as `visible` (for the SVG)."""
    m = master_alpha()
    sw = SYMBOL_W * visible
    sh = sw * m.size[1] / m.size[0]
    ox, oy = optical_offset()
    x0 = -sw / 2 + ox * sw
    y0 = -sh / 2 + oy * sh
    d = 0.15 * sh
    return x0 + sw - d / 2, y0 + sh - d / 2, d


# Shapes -------------------------------------------------------------------
def mask(size: int, shape: str, inset: float = 0.0, radius: float = 0.0) -> Image.Image:
    S = size * SS
    m = Image.new("L", (S, S), 0)
    dr = ImageDraw.Draw(m)
    a, b = inset * SS, S - inset * SS
    if shape == "square":
        dr.rectangle((a, a, b - 1, b - 1), fill=255)
    elif shape == "circle":
        dr.ellipse((a, a, b - 1, b - 1), fill=255)
    elif shape == "rounded":
        dr.rounded_rectangle((a, a, b - 1, b - 1), radius=radius * SS, fill=255)
    elif shape == "squircle":
        n, c, r, pts = 5.0, S / 2, (b - a) / 2, []
        for i in range(720):
            t = 2 * math.pi * i / 720
            ct, st = math.cos(t), math.sin(t)
            pts.append((c + r * math.copysign(abs(ct) ** (2 / n), ct),
                        c + r * math.copysign(abs(st) ** (2 / n), st)))
        dr.polygon(pts, fill=255)
    else:
        raise ValueError(shape)
    return m.resize((size, size), Image.LANCZOS)


def full_icon(size: int, *, dot: bool = False, opaque: bool = True) -> Image.Image:
    """Full-bleed square: BG + symbol (iOS, Play, master)."""
    img = Image.new("RGBA", (size, size), BG + (255,))
    img = Image.alpha_composite(img, symbol_layer(size, size, FG, dot=dot))
    return img.convert("RGB") if opaque else img


def legacy_icon(size: int, shape: str) -> Image.Image:
    """Pre-API-26 launcher icon: shaped body on transparent canvas."""
    k = size / LEGACY_DP
    body = LEGACY_BODY_DP * k
    inset = (LEGACY_DP - LEGACY_BODY_DP) / 2 * k
    img = Image.new("RGBA", (size, size), BG + (255,))
    img = Image.alpha_composite(img, symbol_layer(size, body, FG))
    img.putalpha(mask(size, shape, inset=inset, radius=LEGACY_RADIUS_DP * k))
    return img


def adaptive_fg(size: int, colour=FG, *, dot: bool = False) -> Image.Image:
    return symbol_layer(size, size * ADAPTIVE_VISIBLE_DP / ADAPTIVE_DP, colour, dot=dot)


def save_png(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)


# SVG ----------------------------------------------------------------------
def svg_path() -> tuple[str, float, float]:
    txt = SRC_SVG.read_text()
    vb = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', txt)
    d = re.search(r'\sd="([^"]+)"', txt).group(1)
    return d, float(vb.group(1)), float(vb.group(2))


def svg_icon(canvas: float, visible: float, *, bg: bool, colour=FG, dot: bool = False) -> str:
    d, vw, vh = svg_path()
    sw = SYMBOL_W * visible
    s = sw / vw
    sh = vh * s
    ox, oy = optical_offset()
    tx = canvas / 2 - sw / 2 + ox * sw
    ty = canvas / 2 - sh / 2 + oy * sh
    hexc = "#%02X%02X%02X" % colour
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {canvas:g} {canvas:g}" '
           f'width="{canvas:g}" height="{canvas:g}">']
    if bg:
        out.append(f'<rect width="{canvas:g}" height="{canvas:g}" fill="{BG_HEX}"/>')
    out.append(f'<path transform="translate({tx:.3f} {ty:.3f}) scale({s:.5f})" '
               f'fill="{hexc}" fill-rule="evenodd" d="{d}"/>')
    if dot:
        cx, cy, dd = dot_geometry(visible)
        out.append(f'<circle cx="{canvas / 2 + cx:.3f}" cy="{canvas / 2 + cy:.3f}" '
                   f'r="{dd / 2:.3f}" fill="{ACCENT_HEX}"/>')
    out.append("</svg>\n")
    return "".join(out)


# Android ------------------------------------------------------------------
ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- KovaLink adaptive icon (generated by tool/branding/make_kovalink_icon.py) -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
"""

BG_XML = f"""<?xml version="1.0" encoding="utf-8"?>
<!-- KovaLink adaptive icon background (generated by tool/branding/make_kovalink_icon.py) -->
<resources>
    <color name="ic_launcher_background">{BG_HEX}</color>
</resources>
"""


def write_android(res: Path):
    for q, k in ANDROID_DPI.items():
        d = res / f"mipmap-{q}"
        save_png(legacy_icon(round(LEGACY_DP * k), "rounded"), d / "ic_launcher.png")
        save_png(legacy_icon(round(LEGACY_DP * k), "circle"), d / "ic_launcher_round.png")
        fg = adaptive_fg(round(ADAPTIVE_DP * k))
        save_png(fg, d / "ic_launcher_foreground.png")
        save_png(fg, d / "ic_launcher_monochrome.png")
    any26 = res / "mipmap-anydpi-v26"
    any26.mkdir(parents=True, exist_ok=True)
    (any26 / "ic_launcher.xml").write_text(ADAPTIVE_XML)
    (any26 / "ic_launcher_round.xml").write_text(ADAPTIVE_XML)
    (res / "values").mkdir(parents=True, exist_ok=True)
    (res / "values" / "ic_launcher_background.xml").write_text(BG_XML)


# iOS ----------------------------------------------------------------------
def write_ios(dst: Path, src_contents: Path):
    contents = json.loads(src_contents.read_text())
    dst.mkdir(parents=True, exist_ok=True)
    if dst.resolve() != src_contents.parent.resolve():
        shutil.copy2(src_contents, dst / "Contents.json")
    done = {}
    for im in contents["images"]:
        pt = float(im["size"].split("x")[0])
        px = round(pt * float(im["scale"].rstrip("x")))
        fn = im["filename"]
        if fn not in done:
            save_png(full_icon(px), dst / fn)
            done[fn] = px
    return done


# Preview ------------------------------------------------------------------
def font(size: int):
    for p in ("/usr/share/fonts/google-noto-cjk/NotoSansCJKkr-Medium.otf",
              "/usr/share/fonts/google-noto-cjk/NotoSansCJKkr-Regular.otf"):
        if Path(p).exists():
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def gradient(w: int, h: int, top, bottom) -> Image.Image:
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def adaptive_preview(size: int, shape: str, *, fg_colour=FG, bg=BG, dot=False) -> Image.Image:
    """Simulate a launcher: 108dp layers, mask over the central 72dp."""
    full = round(size * ADAPTIVE_DP / ADAPTIVE_VISIBLE_DP)
    img = Image.new("RGBA", (full, full), bg + (255,))
    img = Image.alpha_composite(img, adaptive_fg(full, fg_colour, dot=dot))
    off = (full - size) // 2
    img = img.crop((off, off, off + size, off + size))
    img.putalpha(mask(size, shape, radius=size * 0.22))
    return img


def ios_preview(size: int, dot=False) -> Image.Image:
    img = full_icon(size, dot=dot, opaque=False)
    img.putalpha(mask(size, "squircle"))
    return img


def preview(path: Path):
    W, PW, PH, HEAD = 1800, 880, 420, 90
    rows = [
        ("기본(앱 적용) — 원형 · 둥근사각 · 스쿼클(iOS)", "base"),
        ("Android 13+ 테마 아이콘(monochrome 레이어)", "mono"),
        ("변형(미적용) — 연결 점 " + ACCENT_HEX, "dot"),
    ]
    H = HEAD + len(rows) * (PH + 20) + 20
    sheet = Image.new("RGB", (W, H), (236, 238, 241))
    dr = ImageDraw.Draw(sheet)
    dr.text((20, 18), "KovaLink 앱 아이콘 미리보기", fill=(20, 20, 20), font=font(34))
    dr.text((20, 58), f"배경 {BG_HEX} · 심볼 #FFFFFF(kovapilot K, 변형 없음) · 심볼 폭 = 보이는 폭의 {SYMBOL_W:.0%}",
            fill=(90, 90, 90), font=font(20))
    walls = {
        "light": ((246, 241, 232), (196, 214, 230), (30, 30, 30)),
        "dark": ((38, 48, 66), (6, 8, 12), (235, 235, 235)),
    }
    themed = {  # Material You style tints (typical Pixel defaults)
        "light": ((0xD6, 0xE3, 0xFF), (0x1B, 0x36, 0x5D)),
        "dark": ((0x2C, 0x37, 0x4A), (0xC6, 0xD8, 0xF5)),
    }
    for ri, (title, kind) in enumerate(rows):
        y0 = HEAD + ri * (PH + 20)
        for ci, wall in enumerate(("light", "dark")):
            x0 = 20 + ci * (PW + 20)
            top, bot, txt = walls[wall]
            panel = gradient(PW, PH, top, bot)
            pd = ImageDraw.Draw(panel)
            pd.text((18, 12), f"{title} / {'밝은' if wall == 'light' else '어두운'} 배경화면",
                    fill=txt, font=font(20))
            big = 136
            icons = []
            for shape in ("circle", "rounded", "squircle"):
                if kind == "base":
                    im = ios_preview(big) if shape == "squircle" else adaptive_preview(big, shape)
                elif kind == "mono":
                    bgc, fgc = themed[wall]
                    im = adaptive_preview(big, shape, fg_colour=fgc, bg=bgc)
                else:
                    im = ios_preview(big, dot=True) if shape == "squircle" else adaptive_preview(big, shape, dot=True)
                icons.append(im)
            for i, im in enumerate(icons):
                x = 40 + i * 190
                panel.paste(im, (x, 70), im)
                lab = "KovaLink"
                tw = pd.textlength(lab, font=font(22))
                pd.text((x + big / 2 - tw / 2, 70 + big + 10), lab, fill=txt, font=font(22))
            # real-pixel small sizes (no upscaling)
            sx = 40 + 3 * 190 + 10
            pd.text((sx, 62), "실제 크기", fill=txt, font=font(18))
            yy = 92
            for s in (48, 36, 24):
                if kind == "mono":
                    bgc, fgc = themed[wall]
                    im = adaptive_preview(s, "circle", fg_colour=fgc, bg=bgc)
                else:
                    im = adaptive_preview(s, "circle", dot=(kind == "dot"))
                panel.paste(im, (sx, yy), im)
                pd.text((sx + s + 12, yy + s / 2 - 12), f"{s}px", fill=txt, font=font(18))
                yy += s + 14
            # 48px icon blown up 3x with nearest neighbour to show pixels
            if kind != "mono":
                im48 = adaptive_preview(48, "rounded", dot=(kind == "dot"))
            else:
                bgc, fgc = themed[wall]
                im48 = adaptive_preview(48, "rounded", fg_colour=fgc, bg=bgc)
            z = im48.resize((144, 144), Image.NEAREST)
            panel.paste(z, (40, 260), z)
            pd.text((200, 300), "← 48px 화면을 3배 확대(픽셀 그대로)", fill=txt, font=font(18))
            if kind == "base":
                # legacy (API 24-25) icon at 48dp xxxhdpi
                lg = legacy_icon(192, "rounded").resize((144, 144), Image.LANCZOS)
                panel.paste(lg, (560, 260), lg)
                pd.text((715, 300), "API 24–25", fill=txt, font=font(18))
                pd.text((715, 326), "기존형 아이콘", fill=txt, font=font(18))
            sheet.paste(panel, (x0, y0))
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, optimize=True)


# Branding folder / pack ---------------------------------------------------
README_KO = f"""# KovaLink 앱 아이콘 묶음

kovapilot 브랜드 패키지의 흑백 'K' 심볼(승인본, 모양 변경 없음)을 KovaLink 앱 아이콘 틀에 배치한 것.
다시 만들기: 레포에서 `python3 tool/branding/make_kovalink_icon.py --pack <폴더> --zip <파일>` (Pillow 필요).

## 색
- 배경: `{BG_HEX}` (KovaLink 어두운 화면 배경과 같은 거의 검은색)
- 심볼: `#FFFFFF`
- 변형(미적용)의 연결 점: `{ACCENT_HEX}` (KovaLink 강조색)

## 배치
- 심볼 폭 = 보이는 아이콘 폭의 {SYMBOL_W:.0%} (1024 기준 약 {round(SYMBOL_W * 1024)}px, 높이는 원본 비율 1.64:1 유지).
- 상하좌우는 심볼 무게중심과 외곽 상자 중심의 중간(시각 중심)으로 맞춤.
- Android 적응형: 108dp 캔버스, 심볼 폭 {SYMBOL_W * ADAPTIVE_VISIBLE_DP:.1f}dp, 심볼 전체가 지름 {ADAPTIVE_SAFE_DP}dp 안전영역 안.

## 파일
- `master/kovalink_icon_1024.png` 1024×1024, 투명도 없음 — 마스터
- `master/kovalink_icon_512_playstore.png` 512×512, 투명도 없음 — Google Play 스토어 등록용
- `master/kovalink_icon.svg` 1024 사각 SVG(배경 포함)
- `master/kovalink_icon_foreground.svg` 108 단위 적응형 앞 레이어(투명 배경)
- `master/kovalink_icon_monochrome.svg` 108 단위 테마 아이콘 레이어(흰색, 시스템이 색칠)
  - SVG 심볼은 브랜드 패키지의 자동 추적 근사 벡터라 큰 크기에서 가장자리가 PNG보다 약간 울퉁불퉁할 수 있음. 앱에는 PNG를 씀.
- `android/res/` — 그대로 `android/app/src/main/res/`에 복사
  - `mipmap-<mdpi~xxxhdpi>/ic_launcher.png` 48/72/96/144/192px — API 24–25용 둥근사각
  - `mipmap-*/ic_launcher_round.png` 같은 크기 원형
  - `mipmap-*/ic_launcher_foreground.png` 108/162/216/324/432px — 적응형 앞 레이어
  - `mipmap-*/ic_launcher_monochrome.png` 같은 크기 — Android 13+ 테마 아이콘
  - `mipmap-anydpi-v26/ic_launcher.xml`, `ic_launcher_round.xml` — 적응형 정의(background·foreground·monochrome)
  - `values/ic_launcher_background.xml` — 배경색 `{BG_HEX}`
  - AndroidManifest `<application>`: `android:icon="@mipmap/ic_launcher"`, `android:roundIcon="@mipmap/ic_launcher_round"`
- `ios/AppIcon.appiconset/` — Xcode AppIcon 세트 전체(20~1024, 모두 투명도 없음) + Contents.json
- `variant_link_dot/` — 변형 1개(앱에 적용 안 함): 오른쪽 아래 빈 자리에 강조색 연결 점
- `preview/kovalink_icon_preview.png` — 원형·둥근사각·스쿼클, 밝은/어두운 배경화면, 48/36/24px, 테마 아이콘 미리보기
"""

BRAND_README = f"""# KovaLink app icon

Source: kovapilot brand package `01_logo/icon/white/` (approved K symbol, unchanged) in `source/`.
Generator: `tool/branding/make_kovalink_icon.py` (rewrites Android/iOS icon resources and this folder).

- Background `{BG_HEX}`, symbol `#FFFFFF`, symbol width {SYMBOL_W:.0%} of the visible icon, optical centring.
- `kovalink_icon_1024.png` master (opaque), `kovalink_icon_512_playstore.png` Play listing (opaque).
- `kovalink_icon.svg`, `kovalink_icon_foreground.svg`, `kovalink_icon_monochrome.svg` (traced approximate vector).
- `kovalink_icon_foreground_432.png` adaptive foreground layer (108dp @ xxxhdpi).
- `variant_link_dot/` optional variant with an accent dot `{ACCENT_HEX}` — not applied to the app.
- `kovalink_icon_preview.png` launcher mock-up.
"""


def write_branding(dst: Path):
    dst.mkdir(parents=True, exist_ok=True)
    save_png(full_icon(1024), dst / "kovalink_icon_1024.png")
    save_png(full_icon(512), dst / "kovalink_icon_512_playstore.png")
    save_png(adaptive_fg(432), dst / "kovalink_icon_foreground_432.png")
    (dst / "kovalink_icon.svg").write_text(svg_icon(1024, 1024, bg=True))
    (dst / "kovalink_icon_foreground.svg").write_text(svg_icon(108, ADAPTIVE_VISIBLE_DP, bg=False))
    (dst / "kovalink_icon_monochrome.svg").write_text(svg_icon(108, ADAPTIVE_VISIBLE_DP, bg=False))
    v = dst / "variant_link_dot"
    v.mkdir(exist_ok=True)
    save_png(full_icon(1024, dot=True), v / "kovalink_icon_link_dot_1024.png")
    save_png(full_icon(512, dot=True), v / "kovalink_icon_link_dot_512_playstore.png")
    save_png(adaptive_fg(432, dot=True), v / "kovalink_icon_link_dot_foreground_432.png")
    (v / "kovalink_icon_link_dot.svg").write_text(svg_icon(1024, 1024, bg=True, dot=True))
    preview(dst / "kovalink_icon_preview.png")
    (dst / "README.md").write_text(BRAND_README)


def write_pack(pack: Path):
    if pack.exists():
        shutil.rmtree(pack)
    m = pack / "master"
    m.mkdir(parents=True)
    for f in ("kovalink_icon_1024.png", "kovalink_icon_512_playstore.png", "kovalink_icon.svg",
              "kovalink_icon_foreground.svg", "kovalink_icon_monochrome.svg"):
        shutil.copy2(BRAND / f, m / f)
    write_android(pack / "android" / "res")
    write_ios(pack / "ios" / "AppIcon.appiconset", IOS / "Contents.json")
    shutil.copytree(BRAND / "variant_link_dot", pack / "variant_link_dot")
    (pack / "preview").mkdir()
    shutil.copy2(BRAND / "kovalink_icon_preview.png", pack / "preview" / "kovalink_icon_preview.png")
    (pack / "README_KO.md").write_text(README_KO)


def make_zip(pack: Path, out: Path):
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for p in sorted(pack.rglob("*")):
            if p.is_file():
                z.write(p, Path(pack.name) / p.relative_to(pack))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pack", type=Path, help="also build the download pack folder here")
    ap.add_argument("--zip", type=Path, help="zip the pack folder to this file (needs --pack)")
    args = ap.parse_args()
    ox, oy = optical_offset()
    print(f"optical offset (symbol units): x={ox:+.4f} y={oy:+.4f}")
    write_branding(BRAND)
    write_android(RES)
    sizes = write_ios(IOS, IOS / "Contents.json")
    print("ios:", ", ".join(f"{k}={v}" for k, v in sorted(sizes.items(), key=lambda kv: kv[1])))
    if args.pack:
        write_pack(args.pack)
        if args.zip:
            make_zip(args.pack, args.zip)
            print("zip:", args.zip, args.zip.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
