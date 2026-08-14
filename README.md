# Bye Bye Diabetes

AI-powered diabetes risk and lifestyle companion. Bangladesh-first, built as a localisation engine.

**Specs:** [`ByeByeDiabetes_PRD_v2.md`](ByeByeDiabetes_PRD_v2.md) · [`Datasets_and_Accuracy_Playbook.md`](Datasets_and_Accuracy_Playbook.md)

---

## Build order

| Stage | What | Status |
|---|---|---|
| **0** | Data acquisition → leakage audit → **freeze `feature_spec.json`** | ✅ **done** — contract frozen at v1.0.0 |
| **2** | Model A training + calibration + honest accuracy report | ✅ **done** — AUC 0.810, ECE 0.020 |
| **1** | FastAPI + Postgres backend, Account/Profile schema, RLS, safety rails | 🔨 next |
| **3** | Wire model into `/risk/assess`, export ONNX for on-device | ⏳ |
| **4** | Flutter app — risk-model vertical slice | ⏳ |

Stage 2 landed before Stage 1 because the leakage audit had to settle which features exist before the DB schema could be written against them. It was the right call — the audit removed three fields from the model.

## Model A — current results

| Metric | Value |
|---|---|
| AUC-ROC | **0.810** |
| Sensitivity / specificity at the shipped threshold | **85.1% / 66.9%** |
| Expected calibration error | **0.020** |
| External validation (DiaBD, Bangladesh) | 0.639 — market runs clinical-score-only |

Full disclosure in [docs/model_card.md](docs/model_card.md). Two findings worth knowing:

**Waist beats volume.** Neither BRFSS nor DiaBD records waist circumference — only NHANES does. Training on 5,843 NHANES rows (89% waist) beat 437,000 pooled rows (1.2% waist) on the metric that matters: 66.9% vs 52.9% specificity at 85% sensitivity. See [docs/data_audit.md](docs/data_audit.md).

**We rejected a 0.94 AUC model.** Three features would have raised the headline from 0.806 to 0.9365 — and made it *0.18 AUC worse* on users who have never been screened, which is exactly who this product is for. See [docs/leakage_audit.md](docs/leakage_audit.md).

Stage 0 comes first because `feature_spec.json` is the contract that the DB schema, the API, and the onboarding wizard are all built against. Discovering during training that a feature must be dropped for leakage is cheap now and expensive later.

**First scope:** onboarding → health profile → Tier-1 risk assessment → factor breakdown → what-if simulator, end to end. Food vision, clinician mode, multi-profile UI, and the AI coach are deliberately out (PRD §16 names scope explosion as a top risk) — though the **Account/Profile split and `profile_id` keying go in from commit #1**, because retrofitting those is a rewrite.

## Layout

```
ml/        scripts/ pipelines/ contracts/ tests/ artifacts/ reports/
backend/   FastAPI app, alembic migrations, RLS policies, tests
app/       Flutter (not yet created)
packs/     region packs — _schema.json + bd/in/ae/us/gb/de.json
docs/      data_acquisition · licensing · internationalisation · leakage_audit · model_card
data/      raw/ interim/ processed/   (gitignored; MANIFEST.json tracks checksums)
```

## Global from day one

One **core model** trained on pooled multi-country data, plus a **swappable per-region calibration layer** (cutoffs + prevalence prior + isotonic recalibration). Adding a market ships a config file and a validation set — never a retrain, never a code branch.

Six packs exist today (`bd` `in` `ae` `us` `gb` `de`), covering all five launch waves, three clinical scores, both regulatory wordings, and RTL. All are honestly marked `not_validated`, which means the app degrades to a transparent clinical score and says so.

```powershell
python ml/scripts/validate_packs.py     # schema + safety-floor + regulatory checks
python -m pytest ml/tests -q
```

The validator enforces what a JSON Schema can't: a pack may make a safety threshold **stricter, never looser**; clinician mode is forbidden in EU/UK packs; regulated markets must use the `metabolic_health_score` wording; and a pack's clinical score must agree with the ML routing table.

See [docs/internationalisation.md](docs/internationalisation.md) — including an **open design gap on diaspora users** that needs a decision before the schema freezes.

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
