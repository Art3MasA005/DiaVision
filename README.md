# DiaVision

Diabetes risk screening and lifestyle companion. Bangladesh-first, built as a localisation engine.

Eleven questions, no blood test, about two minutes — and back comes a calibrated
**range** for whether someone already has undetected high blood sugar, with the
two or three things they can actually change about it. In English and Bangla.

> **Not a medical device.** It does not diagnose or treat anything, its estimates
> can be wrong, and it has been reviewed by no medical regulator. See [LICENSE](LICENSE).

**Specs:** [`DiaVision_PRD_v2.md`](DiaVision_PRD_v2.md) · [`Datasets_and_Accuracy_Playbook.md`](Datasets_and_Accuracy_Playbook.md) · [`docs/ui_spec.md`](docs/ui_spec.md)

---

## Build order

| Stage | What | Status |
|---|---|---|
| **0** | Data acquisition → leakage audit → **freeze `feature_spec.json`** | ✅ **done** — contract frozen at v1.0.0 |
| **2** | Model A training + calibration + honest accuracy report | ✅ **done** — AUC 0.810, ECE 0.020 |
| **1** | FastAPI + Postgres backend, Account/Profile schema, RLS, safety rails | ✅ **done** — 143 tests |
| **3** | Wire model into `/risk/assess` | ✅ **done** — ONNX export still open |
| **4** | Flutter app — all 19 screens, EN + BN, light + dark | ✅ **done** — 55 tests, 28 screen goldens |

Stage 2 landed before Stage 1 because the leakage audit had to settle which features exist before the DB schema could be written against them. It was the right call — the audit removed three fields from the model.

## Running it

```powershell
.\run.ps1          # backend + app on an Android emulator
.\run.ps1 -Web     # backend + app in Chrome
```

Needs PostgreSQL, `python backend/scripts/setup_db.py` once, then
`alembic -c backend/alembic.ini upgrade head` (it also works on an empty
database). Password reset emails need `SMTP_*` in `backend/.env`; without
it, development prints the code in the server log.
Details in [app/README.md](app/README.md).

## What is actually built, and what is honestly stubbed

The app is complete as a product surface: eleven questions → a calibrated risk
range → tracking, check-ins, activity, vitals, insights and a clinician report,
in English and Bangla, light and dark, with the safety machinery wired through.

**The AI coach and the food camera run on a language model** —
`qwen/qwen3.7-flash` through [OpenRouter](https://openrouter.ai). Set
`OPENROUTER_API_KEY` in `backend/.env` to switch them on. The coach reads the
user's own profile, risk estimate, readings, meals, check-ins and activity
straight from the database, so nobody has to type their numbers into a chat.
The safety guards (red flags, medication, the diagnosis question) still run
before the model sees a message. Without a key, or with OpenRouter down, both
fall back: the coach to fixed wording, the camera to search.

**Payment** still has no real implementation and says so on screen.
[app/README.md](app/README.md#things-built-honestly-rather-than-faked)
explains why.

The most interesting bugs found while building it are written up there too,
including one where the API told users a dangerous glucose reading had been
recorded and the row was being rolled back by the very exception that carried
the message.

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

`feature_spec.json` froze first because it is the contract the DB schema, the API and the onboarding wizard are all generated against. Discovering during training that a feature must be dropped for leakage was cheap then and would have been expensive later.

**Still out of scope:** clinician mode and multi-profile UI (PRD §16 names scope explosion as a top risk) — though the **Account/Profile split and `profile_id` keying went in from commit #1**, because retrofitting those is a rewrite.

## Layout

```
ml/             scripts/ pipelines/ contracts/ tests/ artifacts/ reports/
backend/        FastAPI app, alembic migrations, RLS policies, 143 tests
app/            Flutter — 19 screens, EN + BN, light + dark, 55 tests
packs/          region packs — _schema.json + bd/in/ae/us/gb/de.json
docs/           data_acquisition · licensing · internationalisation ·
                leakage_audit · model_card · ui_spec
design_handoff/ the 19-screen design reference the app was built from
data/           raw/ interim/ processed/   (gitignored; MANIFEST.json tracks checksums)
```

## Global from day one

One **core model** trained on pooled multi-country data, plus a **swappable per-region calibration layer** (cutoffs + prevalence prior + isotonic recalibration). Adding a market ships a config file and a validation set — never a retrain, never a code branch.

Six packs exist today (`bd` `in` `ae` `us` `gb` `de`), covering all five launch waves, three clinical scores, both regulatory wordings, and RTL. All are honestly marked `not_validated`, which means the app degrades to a transparent clinical score and says so.

```powershell
python ml/scripts/validate_packs.py     # schema + safety-floor + regulatory checks
python -m pytest ml/tests -q
```

The validator enforces what a JSON Schema can't: a pack may make a safety threshold **stricter, never looser**; clinician mode is forbidden in EU/UK packs; regulated markets must use the `metabolic_health_score` wording; and a pack's clinical score must agree with the ML routing table.

See [docs/internationalisation.md](docs/internationalisation.md). The **diaspora gap** it raises — a Bangladeshi in London scored against European cutoffs instead of Asian-Pacific — is resolved in the ML layer by an optional, user-declared `ancestry_cutoff_group`, and the app collects it on a screen worded as *which population's guidelines*, never as a question about race. The API stores it and passes it to the scorer (migration 0005).

## Reproducing the model

The app runs without this — the trained artefacts are what the API loads. This
is only if you want to retrain.

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r ml/requirements.txt

python ml/scripts/fetch_data.py --all    # downloads what it can, prints steps for the rest
python ml/scripts/inspect_raw.py         # verify what landed
```

See [docs/data_acquisition.md](docs/data_acquisition.md). NHANES is automated; BRFSS and the Mendeley sets need a browser (their hosts block scripted clients). No health data is committed — `data/` is gitignored and `MANIFEST.json` tracks checksums instead.

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

- Python 3.10+
- Flutter 3.32+
- PostgreSQL 15+ — a local instance, or a hosted one (Neon/Supabase free tier)
  with the URL in `backend/.env`. Copy `backend/.env.example` to start.

The application role must **not** be a superuser: a superuser silently bypasses
every row-level security policy, which would make the isolation tests pass while
providing no isolation at all. `backend/scripts/setup_db.py` creates the role
correctly, and the engine refuses to connect if it ever gains those rights.
