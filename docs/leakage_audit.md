# Leakage Audit

**Run:** 14 August 2026 · **Status:** ✅ complete · **Result:** all three suspects excluded from the model
**Raw output:** [`ml/reports/leakage_audit.json`](../ml/reports/leakage_audit.json) · **Reproduce:** `python -m ml.pipelines.leakage_audit`

This audit is the gate that froze [`feature_spec.json`](../ml/contracts/feature_spec.json) at v1.0.0.

---

## The question

Three features were held as `audit_pending` because each is plausibly a consequence of *being inside the healthcare system* rather than of physiology (Playbook §B2):

| Feature | Why suspect |
|---|---|
| `known_high_bp` | Hypertension is frequently diagnosed at the same visit as the diabetes |
| `on_bp_meds` | Being medicated requires a prescription, which requires a doctor |
| `history_high_glucose` | *"Were you ever told you have high blood sugar?"* is close to the label itself — and is unanswerable for someone never tested |

**Our target user is Ashraf: 44, worried, and has never had a blood test.** He answers "no" to all three — not because he is healthy, but because nobody has ever looked.

## Method

Train LightGBM twice on identical splits, once with the suspects and once without, then add each suspect individually. Finally — and this is the test that actually decided it — score both models on the subpopulation that has **never been screened**.

## Results

### Aggregate

| Dataset | Without suspects | With suspects | Delta |
|---|---|---|---|
| BRFSS (431,858) | 0.7720 | 0.8488 | **+0.0768** |
| NHANES (5,843) | 0.8057 | 0.9365 | **+0.1307** |

Adding them individually:

| Feature | BRFSS Δ | NHANES Δ |
|---|---|---|
| `known_high_bp` | +0.0264 | +0.0081 |
| `on_bp_meds` | +0.0290 | +0.0095 |
| **`history_high_glucose`** | **+0.0521** | **+0.1284** |

An AUC of **0.9365** on questionnaire data is exactly the number Playbook §B0 says to treat as a bug rather than a triumph.

### The test that settled it

Restricting to the 787 NHANES adults who have never been told they have high blood pressure *or* high blood glucose — Ashraf's population:

| Model | All users | **Never-screened users** |
|---|---|---|
| With suspects | 0.9365 | **0.6032** |
| Without suspects | 0.8057 | **0.7856** |

> The model that looks **0.13 AUC better** overall is **0.18 AUC worse** on the only users who matter.

Its entire apparent advantage was recognising people already in the healthcare system. On someone who has never seen a doctor it collapses to barely better than a coin flip, while the clean model holds at 0.786.

Had we shipped the 0.9365 model, the published accuracy would have looked outstanding and the product would have failed precisely the users it exists for — and the offline metrics would never have shown it.

## Decision

All three are **`clinical_score_only`**: still collected from the user, still scored by FINDRISC and ADA (where they are legitimate, published inputs), but **excluded from the gradient booster**.

This is not a compromise. The clinical score is transparent — a user can see that answering "yes" to a prior high-glucose reading raised their score, and *why*. The danger is a black-box model silently leaning on it and then failing on people who cannot answer.

## Features excluded outright

Present in BRFSS, never collected and never trained on:

`CholCheck` · `AnyHealthcare` · `NoDocbcCost` · `HighChol` · `DiffWalk` · `GenHlth` · `PhysHlth` · `MentHlth` · `HeartDiseaseorAttack` · `Stroke`

Each is a consequence of the disease or of healthcare access. `GenHlth` (self-rated health) is especially treacherous: it is heavily coloured by *knowing your diagnosis*.

## Consequences

1. `feature_spec.json` frozen at **v1.0.0**. Changing a feature now is a breaking change across the DB schema, the API, and the Flutter wizard.
2. The honest Tier-1 ceiling is **AUC ≈ 0.81**, not 0.94. That is a good model (Playbook §B0: 0.78–0.86 is the realistic band).
3. The model card must state this audit, including the never-screened figure. It is the strongest evidence we have that the model was built honestly, and it is exactly what Apple 1.4.1 and the FDA CDS guidance ask to see.

## Re-run when

- A new dataset is added to the training corpus
- Any feature changes status
- Before each market's first launch (healthcare-contact patterns differ by country — a feature clean in the US may leak in Bangladesh)
