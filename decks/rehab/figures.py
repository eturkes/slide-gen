# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Render the aggregate data-quality figure with the installed Chromium.

Values are copied from committed source
``rehab/models/dataquality_summary.json:9-21``. Only aggregate counts enter
the PNG; the ignored row-level report is neither opened nor rendered.
"""

from __future__ import annotations

import html
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "assets" / "data-quality-findings.png"
WIDTH = 1060
HEIGHT = 720

FINDINGS = (
    ("ドメイン / domain", 1052),
    ("項目間 / cross-field", 798),
    ("縦断 / longitudinal", 290),
)
TOTAL = 2140
EPISODES_FLAGGED = 417


def _chromium() -> str:
    wrapper = shutil.which("chromiumfish")
    if wrapper is None:
        raise RuntimeError("chromiumfish is required to render the figure")
    return subprocess.check_output([wrapper, "path"], text=True).strip()


def _svg() -> str:
    plot_x = 286
    plot_w = 650
    scale_max = 1200
    rows = []
    for i, (label, value) in enumerate(FINDINGS):
        y = 262 + i * 128
        bar_w = round(plot_w * value / scale_max)
        rows.append(
            f"""
            <text x="64" y="{y + 35}" class="label">{html.escape(label)}</text>
            <rect x="{plot_x}" y="{y}" width="{plot_w}" height="54" rx="8" class="track"/>
            <rect x="{plot_x}" y="{y}" width="{bar_w}" height="54" rx="8" class="bar"/>
            <text x="{plot_x + bar_w + 18}" y="{y + 38}" class="value">{value:,}</text>
            """
        )

    ticks = []
    for value in (0, 300, 600, 900, 1200):
        x = round(plot_x + plot_w * value / scale_max)
        ticks.append(
            f'<line x1="{x}" y1="236" x2="{x}" y2="630" class="grid"/>'
            f'<text x="{x}" y="665" class="tick">{value:,}</text>'
        )

    return f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><style>
*{{box-sizing:border-box}}html,body{{margin:0;width:{WIDTH}px;height:{HEIGHT}px;overflow:hidden;background:#fff}}
body{{font-family:'Noto Sans','Noto Sans CJK JP',sans-serif}}
</style></head><body>
<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}"
     viewBox="0 0 {WIDTH} {HEIGHT}">
  <rect width="{WIDTH}" height="{HEIGHT}" fill="#ffffff"/>
  <text x="64" y="76" class="title">ルール検出の集計</text>
  <text x="64" y="117" class="subtitle">AGGREGATE RULE FINDINGS</text>
  <line x1="64" y1="148" x2="996" y2="148" class="rule"/>
  <text x="64" y="205" class="meta">合計 / TOTAL</text>
  <text x="238" y="205" class="total">{TOTAL:,}</text>
  <text x="556" y="205" class="meta">対象エピソード / EPISODES FLAGGED</text>
  <text x="996" y="205" text-anchor="end" class="total-small">{EPISODES_FLAGGED:,}</text>
  {"".join(ticks)}
  {"".join(rows)}
  <text x="996" y="696" text-anchor="end" class="source"
  >tracked aggregate summary · counts of rule findings</text>
  <style>
    .title{{font-size:38px;font-weight:800;fill:#1a1a1a}}
    .subtitle{{font-size:17px;font-weight:700;letter-spacing:4px;fill:#8c8c8c}}
    .rule{{stroke:#e3e3e3;stroke-width:2}}
    .meta{{font-size:16px;font-weight:700;letter-spacing:1.6px;fill:#8c8c8c}}
    .total{{font-size:32px;font-weight:800;fill:#b0533a}}
    .total-small{{font-size:29px;font-weight:800;fill:#1a1a1a}}
    .label{{font-size:22px;font-weight:650;fill:#3a3a3a}}
    .track{{fill:#f0efed}}
    .bar{{fill:#b0533a}}
    .value{{font-size:25px;font-weight:800;fill:#1a1a1a}}
    .grid{{stroke:#e3e3e3;stroke-width:1}}
    .tick{{font-size:16px;fill:#8c8c8c;text-anchor:middle}}
    .source{{font-size:14px;letter-spacing:1px;fill:#a7a7a7}}
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
            prefix="rehab-figure-",
            dir="/tmp",
            delete=False,
            encoding="utf-8",
        ) as handle:
            handle.write(_svg())
            temp_html = Path(handle.name)
        fd, png_name = tempfile.mkstemp(suffix=".png", prefix="rehab-figure-", dir="/tmp")
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
