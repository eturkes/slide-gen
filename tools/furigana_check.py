#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
"""Cross-check deck ruby readings with Fugashi + UniDic."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path

import unidic_lite
from fugashi import Tagger

SECTION_START = "<!-- furigana-check:start -->"
SECTION_END = "<!-- furigana-check:end -->"


def new_tagger() -> Tagger:
    """Build Fugashi against the locked lite dictionary, ignoring ambient extras."""
    return Tagger(f'-d "{unidic_lite.DICDIR}"')


@dataclass(frozen=True)
class RubySpan:
    """One ruby base and its author-supplied reading within a Japanese tier."""

    start: int
    end: int
    term: str
    codex_reading: str


@dataclass(frozen=True)
class TierPair:
    """One `.jp` tier and the matching rt-stripped `.jpf` tier."""

    text: str
    rubies: tuple[RubySpan, ...]


@dataclass(frozen=True)
class Token:
    """One UniDic token located in its original tier text."""

    start: int
    end: int
    surface: str
    reading: str | None


@dataclass(frozen=True)
class Finding:
    """A ruby reading requiring human confirmation."""

    entry: int
    term: str
    codex_reading: str
    analyzer_reading: str | None


class DeckTierParser(HTMLParser):
    """Extract ordered `.jp` and `.jpf` tiers plus ruby spans."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.jp: list[str] = []
        self.jpf: list[tuple[str, tuple[RubySpan, ...]]] = []
        self._kind: str | None = None
        self._root_tag: str | None = None
        self._root_depth = 0
        self._text: list[str] = []
        self._text_len = 0
        self._rubies: list[RubySpan] = []
        self._ruby_start: int | None = None
        self._ruby_reading: list[str] = []
        self._in_rt = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if self._kind is None:
            classes = dict(attrs).get("class") or ""
            kinds = {name for name in classes.split() if name in {"jp", "jpf"}}
            if len(kinds) == 1:
                self._begin(kinds.pop(), tag)
            return

        if tag == self._root_tag:
            self._root_depth += 1
        if self._kind != "jpf":
            return
        if tag == "ruby":
            if self._ruby_start is not None:
                raise ValueError("nested <ruby> in .jpf tier")
            self._ruby_start = self._text_len
            self._ruby_reading = []
        elif tag == "rt":
            if self._ruby_start is None or self._in_rt:
                raise ValueError("stray or nested <rt> in .jpf tier")
            self._in_rt = True

    def handle_endtag(self, tag: str) -> None:
        if self._kind is None:
            return
        if self._kind == "jpf":
            if tag == "rt":
                if not self._in_rt:
                    raise ValueError("stray </rt> in .jpf tier")
                self._in_rt = False
            elif tag == "ruby":
                self._finish_ruby()
        if tag == self._root_tag:
            self._root_depth -= 1
            if self._root_depth == 0:
                self._finish_tier()

    def handle_data(self, data: str) -> None:
        if self._kind is None:
            return
        if self._kind == "jpf" and self._in_rt:
            self._ruby_reading.append(data)
            return
        self._text.append(data)
        self._text_len += len(data)

    def finish(self) -> None:
        """Reject an unterminated target tier after the parser reaches EOF."""
        if self._kind is not None:
            raise ValueError(f"unterminated .{self._kind} tier")

    def _begin(self, kind: str, root_tag: str) -> None:
        self._kind = kind
        self._root_tag = root_tag
        self._root_depth = 1
        self._text = []
        self._text_len = 0
        self._rubies = []
        self._ruby_start = None
        self._ruby_reading = []
        self._in_rt = False

    def _finish_ruby(self) -> None:
        if self._ruby_start is None or self._in_rt:
            raise ValueError("malformed <ruby>/<rt> in .jpf tier")
        text = "".join(self._text)
        self._rubies.append(
            RubySpan(
                start=self._ruby_start,
                end=self._text_len,
                term=text[self._ruby_start : self._text_len],
                codex_reading="".join(self._ruby_reading),
            )
        )
        self._ruby_start = None
        self._ruby_reading = []

    def _finish_tier(self) -> None:
        if self._ruby_start is not None or self._in_rt:
            raise ValueError("unterminated <ruby>/<rt> in .jpf tier")
        text = "".join(self._text)
        if self._kind == "jp":
            self.jp.append(text)
        else:
            self.jpf.append((text, tuple(self._rubies)))
        self._kind = None
        self._root_tag = None


def extract_tiers(html: str) -> tuple[TierPair, ...]:
    """Parse and pair every `.jp` tier with the following-order `.jpf` tier."""
    parser = DeckTierParser()
    parser.feed(html)
    parser.close()
    parser.finish()
    if not parser.jp and not parser.jpf:
        raise ValueError("deck has no .jp/.jpf tiers")
    if len(parser.jp) != len(parser.jpf):
        raise ValueError(f"tier count mismatch: {len(parser.jp)} .jp vs {len(parser.jpf)} .jpf")
    pairs: list[TierPair] = []
    for number, (jp, (jpf, rubies)) in enumerate(zip(parser.jp, parser.jpf, strict=True), 1):
        if jp != jpf:
            raise ValueError(f"tier {number}: .jp differs from rt-stripped .jpf")
        pairs.append(TierPair(jp, rubies))
    return tuple(pairs)


def normalize_reading(text: str) -> str:
    """Normalize width and katakana to hiragana for reading comparison."""
    out: list[str] = []
    for char in unicodedata.normalize("NFKC", text):
        code = ord(char)
        if "\u30a1" <= char <= "\u30f6" or char in {"\u30fd", "\u30fe"}:
            out.append(chr(code - 0x60))
        elif not char.isspace():
            out.append(char)
    return "".join(out)


def is_kana(char: str) -> bool:
    """Whether one normalized character is usable as a phonetic alignment anchor."""
    return (
        "\u3041" <= char <= "\u3096"
        or char in {"\u309d", "\u309e", "\u30fc", "\u30fb"}
        or "\u31f0" <= char <= "\u31ff"
    )


def phonetic_surface(text: str) -> str | None:
    """Return a surface fragment's known reading, or None when it contains kanji."""
    reading = normalize_reading(text)
    return reading if all(is_kana(char) for char in reading) else None


def tokenize(text: str, tagger: Tagger) -> tuple[Token, ...]:
    """Run UniDic and map Fugashi's whitespace-free tokens back onto `text`."""
    tokens: list[Token] = []
    cursor = 0
    for word in tagger(text):
        surface = word.surface
        start = text.find(surface, cursor)
        if start < 0 or any(not char.isspace() for char in text[cursor:start]):
            raise ValueError(f"UniDic token could not be aligned after character {cursor}")
        raw_reading = getattr(word.feature, "kana", None)
        reading = None if raw_reading in {None, "", "*"} else normalize_reading(raw_reading)
        end = start + len(surface)
        tokens.append(Token(start, end, surface, reading))
        cursor = end
    if any(not char.isspace() for char in text[cursor:]):
        raise ValueError(f"UniDic left non-whitespace text after character {cursor}")
    return tuple(tokens)


def token_slice_reading(token: Token, start: int, end: int) -> str | None:
    """Read a ruby-overlapping slice using kana inside the full token as anchors."""
    if token.reading is None:
        return None
    relative_start = start - token.start
    relative_end = end - token.start
    units: list[tuple[int, int, str | None]] = []
    for offset, char in enumerate(token.surface):
        known = phonetic_surface(char)
        if known is None and units and units[-1][2] is None:
            unit_start, _, _ = units[-1]
            units[-1] = (unit_start, offset + 1, None)
        else:
            units.append((offset, offset + 1, known))
    boundaries = {0, *(unit_end for _, unit_end, _ in units)}
    if relative_start not in boundaries or relative_end not in boundaries:
        return None

    minimum = [0] * (len(units) + 1)
    for index in range(len(units) - 1, -1, -1):
        known = units[index][2]
        minimum[index] = minimum[index + 1] + (len(known) if known is not None else 1)

    readings: set[str] = set()
    visited: set[tuple[int, int, int | None, int | None]] = set()
    truncated = False

    def align(
        index: int,
        reading_offset: int,
        slice_start: int | None,
        slice_end: int | None,
    ) -> None:
        nonlocal truncated
        if len(readings) > 1:
            return
        surface_offset = units[index - 1][1] if index else 0
        if surface_offset == relative_start:
            slice_start = reading_offset
        if surface_offset == relative_end:
            slice_end = reading_offset
        state = (index, reading_offset, slice_start, slice_end)
        if state in visited:
            return
        if len(visited) >= 10_000:
            truncated = True
            return
        visited.add(state)
        if index == len(units):
            if (
                reading_offset == len(token.reading)
                and slice_start is not None
                and slice_end is not None
            ):
                readings.add(token.reading[slice_start:slice_end])
            return
        known = units[index][2]
        if known is not None:
            if token.reading.startswith(known, reading_offset):
                align(index + 1, reading_offset + len(known), slice_start, slice_end)
            return
        maximum = len(token.reading) - reading_offset - minimum[index + 1]
        for width in range(1, maximum + 1):
            align(index + 1, reading_offset + width, slice_start, slice_end)

    align(0, 0, None, None)
    return next(iter(readings)) if len(readings) == 1 and not truncated else None


def analyzer_reading(text: str, ruby: RubySpan, tokens: Sequence[Token]) -> str | None:
    """Compose UniDic's reading for one ruby span across any token boundaries."""
    parts: list[str] = []
    cursor = ruby.start
    for token in tokens:
        start = max(ruby.start, token.start)
        end = min(ruby.end, token.end)
        if start >= end:
            continue
        if any(not char.isspace() for char in text[cursor:start]):
            return None
        part = token_slice_reading(token, start, end)
        if part is None:
            return None
        parts.append(part)
        cursor = end
    if any(not char.isspace() for char in text[cursor : ruby.end]):
        return None
    reading = "".join(parts)
    return reading or None


def find_reading_gaps(html: str, tagger: Tagger | None = None) -> tuple[Finding, ...]:
    """Return every ruby whose reading UniDic disagrees with or cannot derive."""
    analyzer = tagger or new_tagger()
    findings: list[Finding] = []
    seen: set[Finding] = set()
    for entry, tier in enumerate(extract_tiers(html), 1):
        tokens = tokenize(tier.text, analyzer)
        for ruby in tier.rubies:
            codex = normalize_reading(ruby.codex_reading)
            independent = analyzer_reading(tier.text, ruby, tokens)
            if independent != codex:
                finding = Finding(entry, ruby.term, codex, independent)
                if finding not in seen:
                    seen.add(finding)
                    findings.append(finding)
    return tuple(findings)


def without_managed_section(text: str) -> str:
    """Remove the prior generated block, rejecting ambiguous marker damage."""
    starts = text.count(SECTION_START)
    ends = text.count(SECTION_END)
    if starts == 0 and ends == 0:
        return text
    if starts != 1 or ends != 1:
        raise ValueError("gaps.md has malformed furigana-check markers")
    start = text.index(SECTION_START)
    end = text.index(SECTION_END)
    if end < start:
        raise ValueError("gaps.md has reversed furigana-check markers")
    before = text[:start].rstrip()
    after = text[end + len(SECTION_END) :].strip()
    return "\n\n".join(part for part in (before, after) if part)


def render_gaps(existing: str, findings: Sequence[Finding]) -> str:
    """Replace the generated review block while preserving human-authored gaps."""
    base = without_managed_section(existing)
    if not findings:
        return f"{base.strip() or 'no gaps'}\n"
    base_lines = [line for line in base.splitlines() if line.strip().casefold() != "no gaps"]
    base = "\n".join(base_lines).strip()
    lines = [
        SECTION_START,
        "## Furigana analyzer review",
        "",
        "UniDic could not independently confirm these authored ruby readings:",
        "",
    ]
    for finding in findings:
        analyzer = finding.analyzer_reading or "unknown"
        lines.extend(
            [
                f"- term: {json.dumps(finding.term, ensure_ascii=False)}",
                f"  entry: {finding.entry}",
                f"  codex-reading: {json.dumps(finding.codex_reading, ensure_ascii=False)}",
                f"  analyzer-reading: {json.dumps(analyzer, ensure_ascii=False)}",
                "  human-review: required",
            ]
        )
    lines.append(SECTION_END)
    section = "\n".join(lines)
    return f"{base}\n\n{section}\n" if base else f"{section}\n"


def check_bundle(bundle: Path, tagger: Tagger | None = None) -> tuple[Finding, ...]:
    """Analyze `bundle/deck.html` and idempotently update `bundle/gaps.md`."""
    deck_path = bundle / "deck.html"
    gaps_path = bundle / "gaps.md"
    for path, expected in ((bundle, "directory"), (deck_path, "file"), (gaps_path, "file")):
        mode = path.lstat().st_mode
        valid = stat.S_ISDIR(mode) if expected == "directory" else stat.S_ISREG(mode)
        if not valid:
            raise ValueError(f"{path} is not a real {expected}")
    html = deck_path.read_text(encoding="utf-8")
    existing = gaps_path.read_text(encoding="utf-8")
    findings = find_reading_gaps(html, tagger)
    rendered = render_gaps(existing, findings)
    if rendered != existing:
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=bundle,
                prefix=".furigana-gaps-",
                delete=False,
            ) as output:
                output.write(rendered)
                temporary = Path(output.name)
            temporary.chmod(stat.S_IMODE(gaps_path.stat().st_mode))
            os.replace(temporary, gaps_path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    return findings


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    """Parse the single bundle-directory CLI argument."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path, help="Bundle containing deck.html and gaps.md")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the checker; findings are review gaps, while tool errors are failures."""
    args = parse_args(argv)
    try:
        findings = check_bundle(args.bundle)
    except (OSError, ValueError, RuntimeError) as error:
        print(f"furigana-check: {error}", file=sys.stderr)
        return 1
    print(f"furigana-check: {len(findings)} review gap(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
