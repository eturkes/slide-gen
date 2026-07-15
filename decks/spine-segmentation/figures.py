# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Render the aggregate, non-identifying cohort distribution used on slide 4."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


OUT = Path(__file__).resolve().parent / "assets" / "case_distribution.png"


def main() -> None:
    # Committed aggregate values: spine-segmentation/docs/run_m2.md:53-54.
    bands = ["≥ 0.90", "0.80–<0.90", "0.50–<0.80", "< 0.50"]
    counts = [35, 8, 13, 5]
    colors = ["#b0533a", "#4e4e4e", "#7a7a7a", "#b4b4b4"]

    fig, ax = plt.subplots(figsize=(10.8, 6.8), dpi=180)
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")
    bars = ax.barh(bands, counts, color=colors, height=0.58)
    ax.invert_yaxis()

    ax.set_xlim(0, 40)
    ax.set_xticks([0, 10, 20, 30, 40])
    ax.set_xlabel("CASES", fontsize=12, color="#6c6c6c", labelpad=14)
    ax.set_title(
        "CASE-LEVEL MEAN DICE",
        loc="left",
        fontsize=19,
        fontweight="bold",
        color="#1a1a1a",
        pad=24,
    )
    ax.text(
        0,
        1.015,
        "n = 61  |  disjoint score bands",
        transform=ax.transAxes,
        fontsize=11,
        color="#8c8c8c",
        va="bottom",
    )
    for bar, count in zip(bars, counts, strict=True):
        ax.text(
            count + 0.7,
            bar.get_y() + bar.get_height() / 2,
            str(count),
            va="center",
            ha="left",
            fontsize=15,
            fontweight="bold",
            color="#1a1a1a",
        )

    ax.spines[["top", "right", "left"]].set_visible(False)
    ax.spines["bottom"].set_color("#d8d8d8")
    ax.tick_params(axis="y", length=0, labelsize=13, colors="#3a3a3a", pad=12)
    ax.tick_params(axis="x", labelsize=11, colors="#8c8c8c")
    ax.xaxis.grid(True, color="#ecebea", linewidth=0.8)
    ax.set_axisbelow(True)
    fig.subplots_adjust(left=0.19, right=0.94, top=0.82, bottom=0.16)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT, facecolor="white", bbox_inches="tight", pad_inches=0.16)
    plt.close(fig)


if __name__ == "__main__":
    main()
