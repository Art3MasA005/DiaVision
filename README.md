# Bye Bye Diabetes

AI-powered diabetes risk and lifestyle companion. Bangladesh-first, built as a localisation engine.

**Specs:** [`ByeByeDiabetes_PRD_v2.md`](ByeByeDiabetes_PRD_v2.md) · [`Datasets_and_Accuracy_Playbook.md`](Datasets_and_Accuracy_Playbook.md)

---

## Build order

| Stage | What | Status |
|---|---|---|
| **0** | Data acquisition → leakage audit → **freeze `feature_spec.json`** | 🔨 in progress |
| **1** | FastAPI + Postgres backend, Account/Profile schema, RLS, safety rails | ⏳ |
| **2** | Model A training + calibration + honest accuracy report | ⏳ |
| **3** | Wire model into `/risk/assess`, export ONNX for on-device | ⏳ |
| **4** | Flutter app — risk-model vertical slice | ⏳ |

Stage 0 comes first because `feature_spec.json` is the contract that the DB schema, the API, and the onboarding wizard are all built against. Discovering during training that a feature must be dropped for leakage is cheap now and expensive later.

**First scope:** onboarding → health profile → Tier-1 risk assessment → factor breakdown → what-if simulator, end to end. Food vision, clinician mode, multi-profile UI, and the AI coach are deliberately out (PRD §16 names scope explosion as a top risk) — though the **Account/Profile split and `profile_id` keying go in from commit #1**, because retrofitting those is a rewrite.

## Layout

```
ml/        scripts/ pipelines/ contracts/ artifacts/ reports/
backend/   FastAPI app, alembic migrations, RLS policies, tests
app/       Flutter (not yet created)
packs/     region packs — bd.json, food_bd.csv, gi_table.csv
docs/      data_acquisition · licensing · leakage_audit · model_card · intended_purpose
data/      raw/ interim/ processed/   (gitignored; MANIFEST.json tracks checksums)
```

## Quickstart

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r ml/requirements.txt

python ml/scripts/fetch_data.py --all    # downloads what it can, prints steps for the rest
python ml/scripts/inspect_raw.py         # verify what landed
```

See [docs/data_acquisition.md](docs/data_acquisition.md). NHANES is automated; BRFSS and the Mendeley sets need a browser (their hosts block scripted clients).

## Non-negotiables

These come from PRD §3 and §5.4 and are not up for renegotiation during implementation:

- **Estimate, never diagnose.** No screen says "you have diabetes". Every number ships with a range.
- **No dose logic, ever.** Apple 1.4.2.
- **No vitals from device sensors.** Camera is for food only. Apple 1.4.1 auto-rejects otherwise.
- **Calibration over accuracy.** If the model says 20%, 20 in 100 such users must actually have it. Brier + ECE + reliability curve are reported, not raw accuracy.
- **Split before everything.** Any preprocessing outside the pipeline is a bug. An AUC above ~0.95 on survey data means leakage, not success.
- **Hard safety floors** (1200 kcal women / 1500 men) are overridable by nobody, including a clinician.
- **Row-level security on `profile_id`**, enforced in the database, adversarially tested in CI.

## Prerequisites

- Python 3.10+ ✅
- Flutter ✅
- **PostgreSQL 15+ — not yet installed.** Needed before Stage 1. Either install it locally, or use a hosted instance (Neon/Supabase free tier) and put the URL in `.env`. Docker is also absent, so `docker-compose` is not currently an option.
