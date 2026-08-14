"""Print the shape and columns of everything sitting in data/raw/.

A sanity pass, run after every acquisition. It answers three questions that
have burned people on this kind of project before:

  1. Did we actually get data, or did a soft-404 hand us an HTML page?
  2. How many rows, really? (Published row counts are often wrong.)
  3. What are the columns actually called? Every dataset here uses different
     names for the same concept, and ml/contracts/feature_spec.json has to
     reconcile them.

Usage:
    python ml/scripts/inspect_raw.py              # everything
    python ml/scripts/inspect_raw.py nhanes       # one subdirectory
    python ml/scripts/inspect_raw.py --cols       # list every column name
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[2]
RAW = REPO_ROOT / "data" / "raw"

READERS = {
    ".xpt": lambda p: pd.read_sas(p, format="xport"),
    ".csv": lambda p: pd.read_csv(p, low_memory=False),
    ".xlsx": lambda p: pd.read_excel(p),
    ".xls": lambda p: pd.read_excel(p),
    ".parquet": lambda p: pd.read_parquet(p),
}


def describe(path: Path, show_cols: bool) -> None:
    rel = path.relative_to(RAW).as_posix()
    reader = READERS.get(path.suffix.lower())
    if reader is None:
        print(f"  {rel:44s}  (skipped: {path.suffix or 'no extension'})")
        return
    try:
        df = reader(path)
    except Exception as exc:
        print(f"  {rel:44s}  [UNREADABLE] {type(exc).__name__}: {exc}")
        return

    print(f"  {rel:44s}  {len(df):>8,} rows x {df.shape[1]:>4} cols")
    if show_cols:
        for i in range(0, len(df.columns), 8):
            print(f"      {', '.join(map(str, df.columns[i:i + 8]))}")
    else:
        head = ", ".join(map(str, df.columns[:8]))
        more = f"  …(+{df.shape[1] - 8})" if df.shape[1] > 8 else ""
        print(f"      {head}{more}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("subdir", nargs="?", default="", help="limit to data/raw/<subdir>")
    parser.add_argument("--cols", action="store_true", help="print every column name")
    args = parser.parse_args()

    root = RAW / args.subdir if args.subdir else RAW
    if not root.exists():
        print(f"No such directory: {root}")
        return 1

    files = sorted(p for p in root.rglob("*") if p.is_file() and p.name not in {".gitkeep", "MANIFEST.json"})
    if not files:
        print(f"Nothing in {root.relative_to(REPO_ROOT)} yet. "
              f"Run: python ml/scripts/fetch_data.py --all")
        return 1

    print(f"data/raw/{args.subdir}  —  {len(files)} file(s)\n")
    for path in files:
        describe(path, args.cols)
    return 0


if __name__ == "__main__":
    sys.exit(main())
