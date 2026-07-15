# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Tests for the authoring-time furigana cross-check."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from tools.furigana_check import (
    SECTION_START,
    Token,
    check_bundle,
    extract_tiers,
    find_reading_gaps,
    new_tagger,
    render_gaps,
    token_slice_reading,
)


def deck(reading: str) -> str:
    """Small controlled deck with one context-dependent okurigana reading."""
    return f"""<!doctype html>
<html lang="ja"><body><section class="slide">
<div class="entry">
<div class="jp">学校で学びます。</div>
<div class="jpf"><ruby>学校<rt>{reading}</rt></ruby>で<ruby>学<rt>まな</rt></ruby>びます。</div>
<div class="en">We learn at school.</div>
</div></section></body></html>
"""


class FuriganaCheckTests(unittest.TestCase):
    """Acceptance coverage over real UniDic plus the committed spine deck."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.tagger = new_tagger()

    def run_fixture(self, reading: str) -> tuple[tuple[object, ...], str]:
        with tempfile.TemporaryDirectory() as raw:
            bundle = Path(raw)
            (bundle / "deck.html").write_text(deck(reading), encoding="utf-8")
            (bundle / "gaps.md").write_text("no gaps\n", encoding="utf-8")
            findings = check_bundle(bundle, self.tagger)
            return findings, (bundle / "gaps.md").read_text(encoding="utf-8")

    def test_correct_common_readings_pass(self) -> None:
        findings, gaps = self.run_fixture("がっこう")
        self.assertEqual(findings, ())
        self.assertEqual(gaps, "no gaps\n")

    def test_wrong_common_reading_becomes_structured_gap(self) -> None:
        findings, gaps = self.run_fixture("がくこう")
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0].term, "学校")
        self.assertEqual(findings[0].analyzer_reading, "がっこう")
        self.assertIn('- term: "学校"', gaps)
        self.assertIn('codex-reading: "がくこう"', gaps)
        self.assertIn('analyzer-reading: "がっこう"', gaps)
        self.assertIn("human-review: required", gaps)
        self.assertNotIn("no gaps", gaps)

    def test_split_rubies_align_through_internal_okurigana(self) -> None:
        token = Token(0, 4, "切り替え", "きりかえ")
        self.assertEqual(token_slice_reading(token, 0, 1), "き")
        self.assertEqual(token_slice_reading(token, 2, 3), "か")

    def test_tier_extraction_is_element_agnostic(self) -> None:
        tiers = extract_tiers(
            '<p class="jp">学校</p><p class="jpf"><ruby>学校<rt>がっこう</rt></ruby></p>'
        )
        self.assertEqual(len(tiers), 1)
        self.assertEqual(tiers[0].text, "学校")
        self.assertEqual(tiers[0].rubies[0].codex_reading, "がっこう")

    def test_analyzer_unknown_becomes_structured_gap(self) -> None:
        class UnknownTagger:
            def __call__(self, text: str) -> list[SimpleNamespace]:
                return [SimpleNamespace(surface=text, feature=SimpleNamespace(kana=None))]

        findings = find_reading_gaps(
            '<p class="jp">未知語</p><p class="jpf"><ruby>未知語<rt>みちご</rt></ruby></p>',
            UnknownTagger(),
        )
        self.assertEqual(len(findings), 1)
        self.assertIsNone(findings[0].analyzer_reading)
        self.assertIn('analyzer-reading: "unknown"', render_gaps("no gaps\n", findings))

    def test_bundle_file_symlink_is_rejected_without_target_write(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = root / "bundle"
            bundle.mkdir()
            (bundle / "deck.html").write_text(deck("がくこう"), encoding="utf-8")
            target = root / "outside.md"
            target.write_text("outside sentinel\n", encoding="utf-8")
            (bundle / "gaps.md").symlink_to(target)
            with self.assertRaisesRegex(ValueError, "not a real file"):
                check_bundle(bundle, self.tagger)
            self.assertEqual(target.read_text(encoding="utf-8"), "outside sentinel\n")

    def test_spine_disagreements_route_to_gaps_without_failure(self) -> None:
        root = Path(__file__).resolve().parents[1]
        source = root / "decks" / "spine-segmentation"
        with tempfile.TemporaryDirectory() as raw:
            bundle = Path(raw)
            (bundle / "deck.html").write_text(
                (source / "deck.html").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            (bundle / "gaps.md").write_text(
                (source / "gaps.md").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            findings = check_bundle(bundle, self.tagger)
            first_gaps = (bundle / "gaps.md").read_text(encoding="utf-8")
            rerun = check_bundle(bundle, self.tagger)
            gaps = (bundle / "gaps.md").read_text(encoding="utf-8")
        self.assertEqual(findings, rerun)
        self.assertEqual(gaps, first_gaps)
        self.assertGreater(len(findings), 0)
        self.assertIn(SECTION_START, gaps)
        self.assertIn("human-review: required", gaps)


if __name__ == "__main__":
    unittest.main()
