#!/usr/bin/env python3
"""Build Sumibi's reading-to-homophone index from pinned SudachiDict Core CSV ZIPs."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import unicodedata
import zipfile
from collections import defaultdict
from pathlib import Path

SOURCE_VERSION = "20260723"
SOURCE_SHA256 = {
    "small_lex.zip": "b578ac9545899783d5d7e30d5d78d5d9dcf40b36965d4af0663ec2eb041c1093",
    "core_lex.zip": "a2b39e1572adab08a649b1390b134517adc55f1d733c59358b113298788bf31c",
}


def check_source(path: Path) -> None:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    expected = SOURCE_SHA256[path.name]
    if digest.hexdigest() != expected:
        raise ValueError(f"Unexpected SudachiDict source: {path}")


def hiragana(reading: str) -> str | None:
    reading = unicodedata.normalize("NFKC", reading)
    if not reading or any(not ("ァ" <= char <= "ヶ" or char == "ー") for char in reading):
        return None
    return "".join(chr(ord(char) - 0x60) if "ァ" <= char <= "ヶ" else char for char in reading)


def contains_kanji(surface: str) -> bool:
    return any("\u3400" <= char <= "\u9fff" or char in "々〆〇" for char in surface)


def entries(archive_path: Path, member: str):
    with zipfile.ZipFile(archive_path) as archive:
        with archive.open(member) as source:
            for row in csv.reader(io.TextIOWrapper(source, encoding="utf-8", newline="")):
                if len(row) < 13 or row[5:7] != ["名詞", "普通名詞"]:
                    continue
                reading = hiragana(row[11])
                surface = row[4]
                if not reading or not contains_kanji(surface) or "\t" in surface or "\n" in surface:
                    continue
                try:
                    cost = int(row[3])
                except ValueError:
                    continue
                yield reading, surface, cost


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--small", type=Path, required=True, help="Official small_lex.zip")
    parser.add_argument("--core", type=Path, required=True, help="Official core_lex.zip")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    check_source(args.small)
    check_source(args.core)

    by_reading: dict[str, dict[str, int]] = defaultdict(dict)
    for archive, member in ((args.small, "small_lex.csv"), (args.core, "core_lex.csv")):
        for reading, surface, cost in entries(archive, member):
            previous = by_reading[reading].get(surface)
            if previous is None or cost < previous:
                by_reading[reading][surface] = cost

    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write(f"# Derived from SudachiDict Core {SOURCE_VERSION}; see ThirdParty/SudachiDict/LEGAL\n")
        for reading in sorted(by_reading):
            surfaces = by_reading[reading]
            if len(surfaces) < 2:
                continue
            ranked = sorted(surfaces, key=lambda surface: (surfaces[surface], surface))[:32]
            output.write("\t".join((reading, *ranked)) + "\n")


if __name__ == "__main__":
    main()
