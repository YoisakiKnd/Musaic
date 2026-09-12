#!/usr/bin/env python3
"""覆盖率门槛检查（日常可用性计划 T2）。

解析 `flutter test --coverage` 产出的 `coverage/lcov.info`，按层校验覆盖率，
未达标则退出码非零（供 CI 拦截）。

## 为什么不依赖 lcov / genhtml

`lcov` 在 CI 与本地都需要额外安装（macOS 要 brew、Ubuntu 要 apt），
而它对本项目唯一有用的能力只是「解析 lcov.info 算百分比」——
本脚本用标准库即可完成，**零依赖**，任何环境直接可跑。

## 阈值为什么是分层而非单一数字

`sources/` 下四个渠道实现大量是**协议适配代码**（URL 拼装、字段映射、
签名），其正确性依赖真实服务端，单元测试能覆盖的部分天然有限。
用统一的 70% 卡它只会逼出「为凑覆盖率而写的假测试」。

因此：core（纯逻辑，必须高）> features（应用逻辑）> sources（协议适配）。

用法：
    python3 tool/check_coverage.py                 # 用默认阈值
    python3 tool/check_coverage.py --verbose       # 同时列出最差文件
    python3 tool/check_coverage.py --min-total 60  # 覆盖单项阈值
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# 各层最低行覆盖率（%）。调整时请同时更新 docs/daily-use-plan.md。
DEFAULT_THRESHOLDS = {
    "lib/core/": 80.0,
    "lib/features/": 60.0,
    "lib/sources/": 30.0,
    "lib/": 55.0,  # 全项目兜底
}

LCOV_PATH = Path("coverage/lcov.info")


def parse_lcov(path: Path) -> dict[str, tuple[int, int]]:
    """解析 lcov.info → {源文件: (总行数, 命中行数)}。"""
    records: dict[str, tuple[int, int]] = {}
    current: str | None = None
    total = 0
    hit = 0

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("SF:"):
            current = line[3:]
            total = hit = 0
        elif line.startswith("LF:"):
            total = int(line[3:] or 0)
        elif line.startswith("LH:"):
            hit = int(line[3:] or 0)
        elif line == "end_of_record" and current is not None:
            records[current] = (total, hit)
            current = None

    return records


def layer_stats(
    records: dict[str, tuple[int, int]], prefix: str
) -> tuple[int, int]:
    total = hit = 0
    for path, (t, h) in records.items():
        if path.startswith(prefix):
            total += t
            hit += h
    return total, hit


def pct(hit: int, total: int) -> float:
    return 100.0 * hit / total if total else 100.0


def main() -> int:
    parser = argparse.ArgumentParser(description="检查测试覆盖率门槛")
    parser.add_argument("--lcov", type=Path, default=LCOV_PATH)
    parser.add_argument("--verbose", action="store_true", help="列出最差文件")
    parser.add_argument("--min-core", type=float)
    parser.add_argument("--min-features", type=float)
    parser.add_argument("--min-sources", type=float)
    parser.add_argument("--min-total", type=float)
    args = parser.parse_args()

    if not args.lcov.is_file():
        print(
            f"找不到 {args.lcov}。请先运行：flutter test --coverage",
            file=sys.stderr,
        )
        return 2

    thresholds = dict(DEFAULT_THRESHOLDS)
    overrides = {
        "lib/core/": args.min_core,
        "lib/features/": args.min_features,
        "lib/sources/": args.min_sources,
        "lib/": args.min_total,
    }
    for key, value in overrides.items():
        if value is not None:
            thresholds[key] = value

    records = parse_lcov(args.lcov)
    if not records:
        print("lcov.info 未解析出任何记录", file=sys.stderr)
        return 2

    print("覆盖率门槛检查")
    print("-" * 62)
    failures: list[str] = []
    for prefix, minimum in thresholds.items():
        total, hit = layer_stats(records, prefix)
        if total == 0:
            continue
        actual = pct(hit, total)
        ok = actual + 1e-9 >= minimum
        mark = "OK  " if ok else "FAIL"
        label = "全项目" if prefix == "lib/" else prefix.rstrip("/")
        print(
            f"[{mark}] {label:<14} {actual:6.1f}%  "
            f"(阈值 {minimum:.0f}%)   {hit}/{total} 行"
        )
        if not ok:
            failures.append(f"{label}: {actual:.1f}% < {minimum:.0f}%")

    if args.verbose:
        print("-" * 62)
        print("覆盖率最低的文件（>=20 行）")
        rows = [
            (pct(h, t), t, h, path)
            for path, (t, h) in records.items()
            if t >= 20
        ]
        rows.sort()
        for value, total, hit, path in rows[:15]:
            print(f"  {value:5.1f}%  {hit:4}/{total:4}  {path}")

    print("-" * 62)
    if failures:
        print("未达标：")
        for item in failures:
            print(f"  - {item}")
        return 1

    print("全部达标。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
