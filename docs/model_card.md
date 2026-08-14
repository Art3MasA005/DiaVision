# How Our AI Works — Model A (Diabetes Risk)

**Version:** 1.0.0 · **Date:** 14 August 2026 · **Status:** not yet released

> This page is a **regulatory artefact**, not marketing. Apple Guideline 1.4.1 requires accuracy claims for health apps to be backed by disclosed data and methodology, and the FDA's 2026 Clinical Decision Support guidance expects clear documentation of how the software works. It must stay accurate and reachable in one tap from any screen showing a model output.

---

## What this model does

It estimates the probability that an adult **already has undetected type-2 diabetes**, from questions they can answer about themselves without a doctor.

**It is a screening tool, not a diagnosis.** It does not predict whether you will develop diabetes in future — that requires years of follow-up data we do not have, and we do not claim it.

> Its job is not to be a laboratory. Its job is to help the right people decide to get a blood test.

## What it is not

- ❌ Not a diagnosis. Only a blood test ordered by a doctor can confirm diabetes.
- ❌ Not a future prediction. This is about your body *now*.
- ❌ Not a replacement for medical advice.
- ❌ Not validated for under-18s, pregnancy, or type-1 diabetes.

---

## How it works

Two layers, deliberately:

```
final_risk = calibrate( w · gradient_boosted_model + (1−w) · clinical_score )
```

**Layer 1 — a published clinical score.** IDRS for South Asia, ADA for the US, FINDRISC for Europe. These are peer-reviewed, validated instruments. Anyone can check the arithmetic.

**Layer 2 — a gradient-boosted model (LightGBM)** trained on the data below.

The blend weight `w` is tuned on a validation set that neither layer was fitted on. We publish the calibration curve for each market.

Where a market has no local validation data, **we do not run the machine-learning model at all** — the transparent clinical score answers, and the app says so.

## What it looks at

| Used by the model | Collected, but scored only by the clinical instrument |
|---|---|
| Age · Sex at birth · Height · Weight | Known high blood pressure |
| **Waist circumference** · Waist-to-height ratio · BMI | Taking blood-pressure medication |
| Family history · Physical activity · Smoking | Previously told of high blood glucose |

The right-hand column is explained under *Leakage* below. Nothing else is used. We never infer health data from your camera, your location, or your contacts.

## Data it was trained on

| Dataset | Rows | Role | Licence |
|---|---|---|---|
| **NHANES 2017-2018** (CDC) | 5,843 adults | **Primary training.** Lab-confirmed HbA1c and fasting glucose | US public domain |
| **BRFSS 2015** (CDC) | 431,858 adults | Breadth (no waist available) | US public domain |
| **DiaBD** (Bangladesh) | 5,288 patients | **External validation only** — never trained on | See acknowledgements |

Labels are objective where possible: HbA1c ≥ 6.5%, fasting glucose ≥ 7.0 mmol/L, or a reported diagnosis.

## Performance

Measured once on a held-out test set that was never used for training, calibration, or tuning.

| Metric | Value | What it means |
|---|---|---|
| **AUC-ROC** | **0.810** | How well it ranks higher-risk above lower-risk |
| AUC-PR | 0.429 | Precision-recall, more honest when the condition is uncommon |
| **Sensitivity** | **85.1%** | Of people who do have diabetes, we flag 85 in 100 |
| **Specificity** | **66.9%** | Of people who don't, we correctly reassure 67 in 100 |
| **Brier score** | 0.127 | Calibration — lower is better |
| **Expected calibration error** | **0.020** | If we say 20%, the true rate is within ~2 points |

**Calibration matters more than accuracy here**, because we show you a percentage. When the model says 20%, roughly 20 of every 100 such people genuinely have diabetes. Before calibration, the raw model claimed 85% where the truth was 62%; isotonic regression fixed that.

We do not report "accuracy". On a population where 13% have diabetes, a model that says "nobody has it" scores 87% accuracy and is useless.

### An AUC of 0.81 is a good model

A questionnaire cannot beat a blood test. Nothing that knows only your age, weight and waist can know your blood sugar. The realistic ceiling for questionnaire-only screening is **0.78–0.86**, and published claims of 95%+ on survey data almost always indicate a methodological error.

### Where it is weaker

| Subgroup | AUC |
|---|---|
| Men | 0.776 |
| Women | 0.771 |
| Ages 30–39 | 0.765 |
| Ages 50–59 | 0.725 |
| **Ages 18–29** | **0.655** |
| **Ages 60+** | **0.696** |

It is weakest at the extremes of age. We report this because an average hides it.

## Leakage — the most important thing we checked

Three features would have raised our headline AUC from 0.806 to **0.9365**. We excluded them anyway.

Restricting to people who have **never been screened** — our actual target user:

| Model | All users | Never-screened users |
|---|---|---|
| With those features | 0.9365 | **0.6032** |
| Without them | 0.8057 | **0.7856** |

The apparently better model was **0.18 AUC worse** on the people this product exists for. Its advantage came from recognising people already in the healthcare system, not from understanding their bodies.

We could have published 0.94. We publish 0.81, because 0.81 is what you will actually get.

Full method: [leakage_audit.md](leakage_audit.md).

## Validation status by market

Per PRD §7.4b, every market declares its status honestly, and the app degrades to the clinical score where the model is unvalidated.

| Market | Status | Basis |
|---|---|---|
| 🇺🇸 United States | **Provisional** | Trained and tested on NHANES (US population) |
| 🇧🇩 Bangladesh | **Not validated** | External test on DiaBD gave AUC 0.639 — see below |
| 🇮🇳 🇬🇧 🇩🇪 🇦🇪 Others | **Not validated** | No local validation data yet |

### Honest note on Bangladesh

External validation on DiaBD gave **AUC 0.639** — well below the 0.810 measured on US data. Three reasons, and we cannot yet separate them:

1. DiaBD has **no waist measurement**, so the model's strongest feature was unavailable
2. DiaBD's family-history column appears faulty (3.2% prevalence, AUC 0.492)
3. Genuine population difference

Until this is resolved, **Bangladesh runs on the IDRS clinical score alone** and the app says so. Resolving it needs local data with waist measurements — the highest-value item on our roadmap.

## Known limitations

- Trained primarily on a US population; South Asian validation is outstanding
- Training age comes from 5-year bands in BRFSS, coarser than what we ask users
- BRFSS records activity as a yes/no while we ask a five-level question
- Adults 18+ only
- Cross-sectional — says nothing about your future
- At 85% sensitivity, roughly 33 in 100 people without diabetes are still flagged. We consider that acceptable: the cost is an unnecessary blood test, versus missing someone who has the disease.

## Reproducing this

```bash
python ml/scripts/fetch_data.py --all
python -m ml.pipelines.leakage_audit
python -m ml.pipelines.train
```

Everything is version-controlled: the feature contract, the pinned dependencies, the metrics, and this page.

## Acknowledgements

- **NHANES / BRFSS** — CDC/NCHS, US public domain
- **DiaBD** — Prama et al., *Data in Brief* 61:111746, 2025
- **IDRS** — Mohan V, et al. *J Assoc Physicians India* 2005;53:759-63
- **FINDRISC** — Lindström J, Tuomilehto J. *Diabetes Care* 2003;26(3):725-31
- **ADA Risk Test** — Bang H, et al. *Ann Intern Med* 2009;151(11):775-83

---

*Questions about this page: support@byebyediabetes.app*
