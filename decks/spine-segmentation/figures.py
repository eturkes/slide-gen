# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Render the aggregate, non-identifying cohort distribution with Chromium."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "assets" / "case_distribution.png"
WIDTH = 1754
HEIGHT = 1071

# Committed aggregate values: spine-segmentation/docs/run_m2.md:53-54.
BANDS = (
    ("≥ 0.90", 35, "#b0533a"),
    ("0.80-<0.90", 8, "#555555"),
    ("0.50-<0.80", 13, "#898989"),
    ("< 0.50", 5, "#b5b5b5"),
)


def _chromium() -> str:
    wrapper = shutil.which("chromiumfish")
    if wrapper is None:
        raise RuntimeError("chromiumfish is required to render the figure")
    return subprocess.check_output([wrapper, "path"], text=True).strip()


def _svg() -> str:
    plot_x = 250
    plot_w = 1458
    plot_top = 124
    plot_bottom = 932
    bar_height = 119
    rows = []
    for index, (label, count, color) in enumerate(BANDS):
        y = 161 + index * 205
        width = round(plot_w * count / 40)
        rows.append(
            f"""
            <text x="218" y="{y + 74}" class="band">{label}</text>
            <rect x="{plot_x}" y="{y}" width="{width}" height="{bar_height}" fill="{color}"/>
            <text x="{plot_x + width + 26}" y="{y + 77}" class="count">{count}</text>
            """
        )
    ticks = []
    for value in (0, 10, 20, 30, 40):
        x = round(plot_x + plot_w * value / 40)
        ticks.append(
            f'<line x1="{x}" y1="{plot_top}" x2="{x}" y2="{plot_bottom}" class="grid"/>'
            f'<text x="{x}" y="972" class="tick">{value}</text>'
        )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><style>
*{{box-sizing:border-box}}html,body{{margin:0;width:{WIDTH}px;height:{HEIGHT}px;overflow:hidden;background:#fff}}
body{{font-family:'Noto Sans','Noto Sans CJK JP',sans-serif}}
</style></head><body>
<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}"
     viewBox="0 0 {WIDTH} {HEIGHT}">
  <rect width="{WIDTH}" height="{HEIGHT}" fill="#ffffff"/>
  <text x="250" y="65" class="title">CASE-LEVEL MEAN DICE</text>
  <text x="250" y="106" class="subtitle">n = 61  |  disjoint score bands</text>
  {"".join(ticks)}
  {"".join(rows)}
  <line x1="{plot_x}" y1="{plot_bottom}" x2="{plot_x + plot_w}" y2="{plot_bottom}" class="axis"/>
  <text x="979" y="1035" class="axis-title">CASES</text>
  <style>
    .title{{font-size:50px;font-weight:800;letter-spacing:1px;fill:#1a1a1a}}
    .subtitle{{font-size:28px;font-weight:400;letter-spacing:1px;fill:#8c8c8c}}
    .grid{{stroke:#e4e4e4;stroke-width:1}}
    .axis{{stroke:#cfcfcf;stroke-width:2}}
    .band{{font-size:34px;font-weight:400;fill:#3a3a3a;text-anchor:end}}
    .count{{font-size:40px;font-weight:800;fill:#1a1a1a}}
    .tick{{font-size:28px;font-weight:400;fill:#8c8c8c;text-anchor:middle}}
    .axis-title{{font-size:30px;font-weight:500;letter-spacing:1px;fill:#6c6c6c;text-anchor:middle}}
  </style>
</svg></body></html>"""


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    temp_html: Path | None = None
    temp_png: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".html",
            prefix="spine-figure-",
            dir="/tmp",
            delete=False,
            encoding="utf-8",
        ) as handle:
            handle.write(_svg())
            temp_html = Path(handle.name)
        fd, png_name = tempfile.mkstemp(suffix=".png", prefix="spine-figure-", dir="/tmp")
        os.close(fd)
        temp_png = Path(png_name)
        temp_png.unlink()
        subprocess.run(
            [
                _chromium(),
                "--headless=new",
                "--no-sandbox",
                "--disable-gpu",
                "--hide-scrollbars",
                "--force-device-scale-factor=1",
                f"--window-size={WIDTH},{HEIGHT}",
                f"--screenshot={temp_png}",
                temp_html.as_uri(),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        shutil.copyfile(temp_png, OUT)
        temp_png.unlink()
        temp_png = None
    finally:
        if temp_html is not None:
            temp_html.unlink(missing_ok=True)
        if temp_png is not None:
            temp_png.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
