"""Acquire the Stage 0 datasets into data/raw/ and record a reproducibility manifest.

Two kinds of dataset live here:

  AUTO    — public-domain, directly fetchable (NHANES).
  MANUAL  — the host blocks automated clients, or the licence requires a human
            to click through it (BRFSS behind Akamai, Mendeley behind
            Cloudflare, anything with a data-use agreement). For these the
            script prints exact instructions, then checksums whatever you
            placed in data/raw/ so the provenance record is identical either way.

Verified against the live hosts on 2026-08-14. CDC reorganised NHANES onto
year-only folders (`/Public/2017/DataFiles/` serves the 2017-2018 cycle); the
older `/Nchs/Nhanes/2017-2018/` paths now soft-404 to the CDC homepage, which
is worse than a hard 404 because a naive script saves the HTML and moves on.
Hence the magic-bytes check in `_download`.

Usage
-----
    python ml/scripts/fetch_data.py --list
    python ml/scripts/fetch_data.py nhanes        # downloads
    python ml/scripts/fetch_data.py brfss diabd   # prints manual steps, then verifies
    python ml/scripts/fetch_data.py --all
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

try:
    import requests
except ImportError:  # pragma: no cover - guidance path
    sys.exit("requests is not installed. Run: pip install -r ml/requirements.txt")

REPO_ROOT = Path(__file__).resolve().parents[2]
RAW = REPO_ROOT / "data" / "raw"
MANIFEST = RAW / "MANIFEST.json"

CHUNK = 1 << 20
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

# A SAS XPORT file always opens with this. CDC serves its 404s with HTTP 200
# and an HTML body, so status codes alone cannot be trusted.
XPT_MAGIC = b"HEADER RECORD"
ZIP_MAGIC = b"PK\x03\x04"


# ──────────────────────────────────────────────────────────────────────
# Registry
# ──────────────────────────────────────────────────────────────────────

@dataclass
class Dataset:
    key: str
    title: str
    licence: str
    citation: str
    subdir: str
    files: list[tuple[str, str]] = field(default_factory=list)  # (name, url)
    manual: bool = False
    manual_url: str = ""
    manual_steps: list[str] = field(default_factory=list)
    expect: list[str] = field(default_factory=list)  # filenames we hope to find
    magic: bytes | None = None
    note: str = ""


_NHANES_BASE = "https://wwwn.cdc.gov/Nchs/Data/Nhanes/Public/2017/DataFiles/{f}.xpt"

# NHANES 2017-2018 ("J" cycle) — the last complete pre-pandemic cycle with a
# full fasting subsample. The 2017-2020 pre-pandemic release is merged and
# differently weighted; it is not a drop-in substitute.
_NHANES_J = {
    "DEMO_J": "demographics: age, sex, ethnicity, survey weights",
    "BMX_J": "body measures: BMI and BMXWAIST (waist) — a first-class feature",
    "BPX_J": "measured blood pressure",
    "GHB_J": "glycohemoglobin (HbA1c) — objective label",
    "GLU_J": "fasting plasma glucose — objective label",
    "INS_J": "insulin",
    "HDL_J": "HDL cholesterol",
    "TRIGLY_J": "triglycerides + LDL",
    "DIQ_J": "diabetes questionnaire (self-report, family history)",
    "BPQ_J": "BP / cholesterol questionnaire, medication use",
    "SMQ_J": "smoking",
    "PAQ_J": "physical activity",
    "MCQ_J": "medical conditions",
}


DATASETS: dict[str, Dataset] = {
    "nhanes": Dataset(
        key="nhanes",
        title="NHANES 2017-2018 (J cycle) — lab-confirmed HbA1c and fasting glucose",
        licence="US public domain — commercial use permitted",
        citation="CDC/NCHS, National Health and Nutrition Examination Survey, 2017-2018.",
        subdir="nhanes/2017-2018",
        files=[(f"{n}.xpt", _NHANES_BASE.format(f=n)) for n in _NHANES_J],
        magic=XPT_MAGIC,
        note="Objective labels for the Tier-2 (with-labs) model. Not needed for Tier-1.",
    ),
    "brfss": Dataset(
        key="brfss",
        title="CDC BRFSS 2015 — Behavioral Risk Factor Surveillance System",
        licence="US public domain — commercial use permitted",
        citation="Centers for Disease Control and Prevention, BRFSS 2015 Annual Survey Data.",
        subdir="brfss",
        manual=True,
        manual_url="https://www.cdc.gov/brfss/annual_data/annual_2015.html",
        manual_steps=[
            "www.cdc.gov sits behind Akamai bot protection and refuses scripted",
            "clients (HTTP 403). A normal browser is fine. In your browser:",
            "  1. Open https://www.cdc.gov/brfss/annual_data/annual_2015.html",
            "  2. Download 'SAS Transport Format'  ->  LLCP2015XPT.zip  (~90 MB)",
            "  3. Optionally grab the codebook PDF from the same page",
            f"  4. Save into  data/raw/brfss/",
            "  5. Re-run this script to checksum it into the manifest",
        ],
        expect=["LLCP2015XPT.zip"],
        magic=ZIP_MAGIC,
        note=(
            "We use the RAW CDC release, not the cleaned Kaggle mirror: "
            "unambiguously public domain, and deriving the feature set ourselves "
            "is what makes the leakage audit meaningful."
        ),
    ),
    "diabd": Dataset(
        key="diabd",
        title="DiaBD — Diabetes in Bangladesh (5,288 patients)",
        licence="VERIFY on the Mendeley page before any commercial use",
        citation="Prama et al., Data in Brief 61:111746, 2025. doi:10.17632/m8cgwxs9s6.2",
        subdir="diabd",
        manual=True,
        manual_url="https://data.mendeley.com/datasets/m8cgwxs9s6/2",
        manual_steps=[
            "Mendeley Data is behind a Cloudflare challenge that no script can",
            "pass. Download in a browser:",
            "  1. Open https://data.mendeley.com/datasets/m8cgwxs9s6/2",
            "  2. Click 'Download all' (or the individual .csv/.xlsx)",
            "  3. Unzip into  data/raw/diabd/",
            "  4. READ THE LICENCE on that page and record it in docs/licensing.md",
            "  5. Re-run this script to checksum it into the manifest",
        ],
        note="The local calibration + external validation set. The most important file here.",
    ),
    "t2d_bd": Dataset(
        key="t2d_bd",
        title="Type-2 Diabetes Dataset Bangladesh (1,065 patients)",
        licence="VERIFY on the Mendeley page",
        citation="doi:10.17632/rn9m3zb7nt.1",
        subdir="t2d_bd",
        manual=True,
        manual_url="https://data.mendeley.com/datasets/rn9m3zb7nt/1",
        manual_steps=[
            "  1. Open https://data.mendeley.com/datasets/rn9m3zb7nt/1",
            "  2. Download all, unzip into  data/raw/t2d_bd/",
        ],
        note="Second local set. Imbalanced the other way (840 diabetic / 225 not).",
    ),
    "pabna": Dataset(
        key="pabna",
        title="Type-2 Diabetes — Pabna Diabetes Hospital, Bangladesh",
        licence="VERIFY on the Mendeley page",
        citation="doi:10.17632/vxnyysk9vc.2",
        subdir="pabna",
        manual=True,
        manual_url="https://data.mendeley.com/datasets/vxnyysk9vc/2",
        manual_steps=[
            "  1. Open https://data.mendeley.com/datasets/vxnyysk9vc/2",
            "  2. Download all, unzip into  data/raw/pabna/",
        ],
        note="Third local set. Single-hospital selection bias — validation only, never training.",
    ),
}


# ──────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────

def _human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:,.0f} {unit}" if unit == "B" else f"{n:,.1f} {unit}"
        n /= 1024.0
    return f"{n} B"


def _sha256(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as fh:
        while block := fh.read(CHUNK):
            digest.update(block)
            total += len(block)
    return total, digest.hexdigest()


def _download(url: str, dest: Path, magic: bytes | None) -> tuple[int, str]:
    """Stream to disk atomically. Rejects a body that fails the magic-bytes check."""
    tmp = dest.with_suffix(dest.suffix + ".part")
    digest = hashlib.sha256()
    total = 0
    first = b""
    with requests.get(url, stream=True, timeout=180, headers={"User-Agent": USER_AGENT}) as resp:
        resp.raise_for_status()
        # Content-Length describes the compressed body; requests hands us the
        # decompressed stream, so a percentage would exceed 100%. Only trust it
        # when nothing was encoded.
        expected = 0
        if not resp.headers.get("Content-Encoding"):
            expected = int(resp.headers.get("Content-Length") or 0)
        tmp.parent.mkdir(parents=True, exist_ok=True)
        with tmp.open("wb") as fh:
            for block in resp.iter_content(CHUNK):
                if not block:
                    continue
                if not first:
                    first = block[:32]
                    if magic and not first.startswith(magic):
                        fh.close()
                        tmp.unlink(missing_ok=True)
                        raise RuntimeError(
                            f"served content is not the expected format "
                            f"(got {first[:16]!r}) — the URL probably soft-404'd"
                        )
                fh.write(block)
                digest.update(block)
                total += len(block)
                bar = f"{100 * total / expected:5.1f}%  " if expected else ""
                print(f"\r    {bar}{_human(total)}", end="", flush=True)
    print("\r" + " " * 48 + "\r", end="")
    tmp.replace(dest)
    return total, digest.hexdigest()


def _load_manifest() -> dict:
    if MANIFEST.exists():
        return json.loads(MANIFEST.read_text(encoding="utf-8"))
    return {"generated_at": None, "datasets": {}}


def _save_manifest(manifest: dict) -> None:
    manifest["generated_at"] = datetime.now(timezone.utc).isoformat()
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def _record(entry: dict, name: str, size: int, sha: str, url: str) -> None:
    entry["files"][name] = {
        "url": url,
        "bytes": size,
        "sha256": sha,
        "recorded_at": datetime.now(timezone.utc).isoformat(),
    }


# ──────────────────────────────────────────────────────────────────────
# Per-dataset handling
# ──────────────────────────────────────────────────────────────────────

def _handle_manual(ds: Dataset, target: Path, entry: dict) -> bool:
    present = sorted(p for p in target.glob("**/*") if p.is_file() and p.name != ".gitkeep")
    if not present:
        print("    [MANUAL] not present. Do this:")
        for line in ds.manual_steps:
            print(f"      {line}")
        target.mkdir(parents=True, exist_ok=True)
        print(f"      -> destination ready: {target.relative_to(REPO_ROOT)}")
        return False

    print(f"    [found] {len(present)} file(s) — checksumming")
    for path in present:
        size, sha = _sha256(path)
        rel = path.relative_to(target).as_posix()
        if ds.magic:
            with path.open("rb") as fh:
                if not fh.read(len(ds.magic)).startswith(ds.magic):
                    print(f"    [warn] {rel} does not look like the expected format")
        _record(entry, rel, size, sha, ds.manual_url)
        print(f"    [ok]   {rel}  {_human(size)}  sha256:{sha[:16]}…")
    return True


def _handle_auto(ds: Dataset, target: Path, entry: dict, force: bool) -> bool:
    ok = True
    for name, url in ds.files:
        dest = target / name
        if dest.exists() and not force:
            size, sha = _sha256(dest)
            _record(entry, name, size, sha, url)
            print(f"    [skip] {name}  (present, {_human(size)})")
            continue
        try:
            print(f"    [get]  {name}")
            size, sha = _download(url, dest, ds.magic)
            _record(entry, name, size, sha, url)
            print(f"    [ok]   {name}  {_human(size)}  sha256:{sha[:16]}…")
        except Exception as exc:
            print(f"    [FAIL] {name}: {exc}")
            ok = False
            time.sleep(1)
    return ok


def fetch(ds: Dataset, manifest: dict, force: bool) -> bool:
    print(f"\n=== {ds.title}")
    print(f"    licence:  {ds.licence}")
    print(f"    cite:     {ds.citation}")
    if ds.note:
        print(f"    note:     {ds.note}")

    target = RAW / ds.subdir
    entry = manifest["datasets"].setdefault(ds.key, {"files": {}})
    entry.update(
        title=ds.title, licence=ds.licence, citation=ds.citation,
        acquisition="manual" if ds.manual else "auto",
    )
    entry.setdefault("files", {})

    if ds.manual:
        return _handle_manual(ds, target, entry)
    target.mkdir(parents=True, exist_ok=True)
    return _handle_auto(ds, target, entry, force)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("keys", nargs="*", help="dataset keys")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--force", action="store_true", help="re-download present files")
    args = parser.parse_args()

    if args.list:
        for ds in DATASETS.values():
            tag = "MANUAL" if ds.manual else "auto  "
            print(f"{tag}  {ds.key:8s}  {ds.title}")
            print(f"{'':8s}  {'':8s}  licence: {ds.licence}")
        return 0

    keys = list(DATASETS) if args.all else args.keys
    if not keys:
        parser.print_help()
        return 1
    if unknown := [k for k in keys if k not in DATASETS]:
        print(f"Unknown dataset(s): {', '.join(unknown)}\nAvailable: {', '.join(DATASETS)}")
        return 1

    manifest = _load_manifest()
    pending = [k for k in keys if not fetch(DATASETS[k], manifest, args.force)]
    _save_manifest(manifest)

    print(f"\nManifest: {MANIFEST.relative_to(REPO_ROOT)}")
    if pending:
        print(f"Still needed: {', '.join(pending)}")
        print("See docs/data_acquisition.md.")
        return 2
    print("All requested datasets present and checksummed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
