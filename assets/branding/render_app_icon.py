#!/usr/bin/env python3
"""Musaic launcher icon: mosaic-tile quarter note on brand pink.

设计（musaic-power-optimization-plan 之前的图标方案）：四分音符由
2×2 圆角马赛克瓷砖拼成，右上角一块（深色）从槽位上浮错位，
呼应「音乐拼图」。三份产物：
- app_icon.png      不透明母版（iOS / macOS / Windows）
- app_icon_fg.png   透明前景（Android 自适应图标，内容预缩进安全圈）
- app_icon_mono.png 单色白（Android 13 monochrome 主题图标）
无第三方依赖：SDF 抗锯齿 + 手写 PNG 编码。
"""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path
from typing import Callable

SIZE = 1024
CENTER = SIZE / 2

BG = (0xFF, 0x2D, 0x55, 255)  # AppTokens.accent
INK = (0xFF, 0xFF, 0xFF, 255)
PINK = (0xFF, 0xC2, 0xCC, 255)
DARK = (0x15, 0x10, 0x13, 255)  # AppTokens.darkBackground


def _png(path: Path, pixels: list[tuple[int, int, int, int]]) -> None:
    raw = b"".join(
        b"\x00" + bytes(ch for p in pixels[y * SIZE : (y + 1) * SIZE] for ch in p)
        for y in range(SIZE)
    )

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def _cover(sdf: float) -> float:
    return 0.0 if sdf >= 0.7 else 1.0 if sdf <= -0.7 else 0.5 - sdf / 1.4


def _blend(
    buf: list[tuple[int, int, int, int]],
    x: int,
    y: int,
    t: float,
    color: tuple[int, int, int, int],
) -> None:
    if t <= 0:
        return
    r, g, b, a = color
    t *= a / 255
    i = y * SIZE + x
    pr, pg, pb, pa = buf[i]
    out_a = pa / 255 + t * (1 - pa / 255)
    if out_a <= 0:
        return
    buf[i] = (
        int((pr * (pa / 255) * (1 - t) + r * t) / out_a + 0.5),
        int((pg * (pa / 255) * (1 - t) + g * t) / out_a + 0.5),
        int((pb * (pa / 255) * (1 - t) + b * t) / out_a + 0.5),
        int(out_a * 255 + 0.5),
    )


def _fill_sdf(
    buf: list[tuple[int, int, int, int]],
    sdf_at: Callable[[float, float], float],
    color: tuple[int, int, int, int],
) -> None:
    for y in range(SIZE):
        for x in range(SIZE):
            t = _cover(sdf_at(x + 0.5, y + 0.5))
            if t > 0:
                _blend(buf, x, y, t, color)


def _rounded_box_sdf(
    x: float, y: float, cx: float, cy: float, hw: float, hh: float, r: float
) -> float:
    dx = abs(x - cx) - (hw - r)
    dy = abs(y - cy) - (hh - r)
    return math.hypot(max(dx, 0.0), max(dy, 0.0)) + min(max(dx, dy), 0.0) - r


# ---------- 马赛克音符几何（1024 画布） ----------

_T = 170.0  # 瓷砖边长
_G = 12.0  # 拼缝
_R = 44.0  # 瓷砖圆角
_X0 = 436.0  # 头部网格左上
_Y0 = 466.0
_STEM_W = 60.0
_STEM_TOP = 206.0
_STEM_R = 28.0
# 深色块完全脱离网格，悬于左上（对角留 30px 气隙）
_DARK_X = _X0 - 200.0
_DARK_Y = _Y0 - 200.0

# 主构图包围盒：x 236..788，y 206..818（画布中心对称）


def _shapes(scale: float):
    """返回 (颜色, sdf) 列表；scale 绕画布中心缩放（前景安全圈用）。"""

    def xform(v: float) -> float:
        return CENTER + (v - CENTER) * scale

    tiles: list[tuple[tuple[int, int, int, int], float, float]] = [
        # (颜色, 中心 x, 中心 y) —— 完整 2×2 棋盘格
        (INK, _X0 + _T / 2, _Y0 + _T / 2),  # 左上 白
        (PINK, _X0 + _T + _G + _T / 2, _Y0 + _T / 2),  # 右上 浅粉
        (PINK, _X0 + _T / 2, _Y0 + _T + _G + _T / 2),  # 左下 浅粉
        (INK, _X0 + _T + _G + _T / 2, _Y0 + _T + _G + _T / 2),  # 右下 白
    ]
    dark_cx = _DARK_X + _T / 2
    dark_cy = _DARK_Y + _T / 2
    stem_cx = _X0 + 2 * _T + _G - _STEM_W / 2
    stem_cy = (_STEM_TOP + _Y0 + _T * 1.35) / 2

    out: list[tuple[tuple[int, int, int, int], Callable[[float, float], float]]] = []

    def box(cx: float, cy: float, hw: float, hh: float, r: float):
        cx2, cy2 = xform(cx), xform(cy)
        h2 = hw * scale
        return lambda x, y: _rounded_box_sdf(x, y, cx2, cy2, h2, hh * scale, r * scale)

    # 符干先画（底部压在右下瓷砖下），再画瓷砖
    out.append(
        (INK, box(stem_cx, stem_cy, _STEM_W / 2, (_Y0 + _T * 1.35 - _STEM_TOP) / 2, _STEM_R))
    )
    for color, cx, cy in tiles:
        out.append((color, box(cx, cy, _T / 2, _T / 2, _R)))
    out.append((DARK, box(dark_cx, dark_cy, _T / 2, _T / 2, _R)))
    return out


def _paint_note(
    buf: list[tuple[int, int, int, int]], scale: float = 1.0, mono: bool = False
) -> None:
    for color, sdf in _shapes(scale):
        if mono:
            color = INK
        _fill_sdf(buf, sdf, color)


def main() -> None:
    out_dir = Path(__file__).resolve().parent

    opaque = [BG] * (SIZE * SIZE)
    _paint_note(opaque)
    _png(out_dir / "app_icon.png", opaque)

    foreground = [(0, 0, 0, 0)] * (SIZE * SIZE)
    # 自适应图标安全圈 = 画布 66/108 ≈ 0.61；构图最远点半径 ≈ 412px，
    # 缩放 0.75 后 ≈ 309px < 312px，内容完整落在安全圈内
    _paint_note(foreground, scale=0.75)
    _png(out_dir / "app_icon_fg.png", foreground)

    monochrome = [(0, 0, 0, 0)] * (SIZE * SIZE)
    _paint_note(monochrome, scale=0.75, mono=True)
    _png(out_dir / "app_icon_mono.png", monochrome)


if __name__ == "__main__":
    main()
