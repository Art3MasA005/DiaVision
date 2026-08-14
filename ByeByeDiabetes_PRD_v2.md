# Bye Bye Diabetes — Product Requirements Document (PRD)

**Version:** 2.0
**Date:** 13 August 2026
**Platforms:** iOS (App Store), Android (Google Play), Web (Clinician Portal)
**Business model:** Paid / Freemium subscription + B2B clinic tier
**Market strategy:** Global product, Bangladesh-first launch (see §1.2)

**Changes from v1.0:** international market architecture (§1.2, §3.5, §13); daily health check-in and longitudinal monitoring (F14); multi-profile / family accounts (F15); clinician mode and patient roster (F16); trajectory model (§7.5); expanded international regulatory matrix (§3.5); expanded dataset appendix (§17.4).

---

## 0. How to use this document

- **For Claude Design:** Use §12 (Screen Inventory) and §13 (Design System, incl. §13.2 i18n constraints) to generate UI.
- **For Claude Code:** Use §6 (Feature Specs), §8 (Data Model), §9 (Tech Stack), §10 (API Surface) as the build brief.
- **For the ML work:** Use §7 (AI/ML System Design) and §17 (Dataset Appendix).
- **Read §3 and §5 before writing a single line of code.** They contain the constraints that decide whether this app gets approved or rejected — and, in §3.5, whether you become a regulated medical device.
- **Lock the Account/Profile split (§8) in Phase 0.** Retrofitting multi-profile onto a `user_id` schema means rewriting every table and every query.

---

## 1. Product Vision

**One-line:** Bye Bye Diabetes is an AI-powered diabetes risk and lifestyle companion for the whole household — it estimates each person's type-2 diabetes risk, tracks it daily, and guides food, portions, and movement using the food that is actually on *their* table, wherever in the world that table is.

**Why it wins:** Every major nutrition app is built on a Western food database and a Western risk curve. A user in Dhaka logging *ilish bhaji with panta bhat*, a user in Lagos logging *jollof rice*, and a user in Mexico City logging *tacos al pastor* all get garbage. Diabetes is a global disease with radically local food. Bye Bye Diabetes is built as a **localisation engine**: swap the food pack and the risk calibration, keep the same core product.

**Positioning statement:**
> For adults anywhere who are worried about diabetes or already living with it — and for the family members and doctors who help them — Bye Bye Diabetes is a daily health companion that estimates risk, recognises *local* meals from a photo, and coaches portion-by-portion. Unlike global calorie apps, it understands regional cuisine and population-specific risk thresholds.

### 1.2 Market sequencing (global, but not everywhere at once)

Going international does **not** mean launching everywhere on day one. Each market needs a *food pack* + *risk calibration* + *regulatory clearance path*, and that is expensive. Sequence:

| Wave | Markets | Why | What's needed |
|---|---|---|---|
| **Wave 1 (Launch)** | Bangladesh | Home market, FoodBD dataset, lowest regulatory friction, cheapest CAC | BD food pack, DiaBD calibration |
| **Wave 2 (Month 4–9)** | India, Pakistan, Sri Lanka, Nepal + South Asian diaspora in UK/US/Canada/Gulf | Shared cuisine → food pack reuse is ~60%. Highest diabetes prevalence on earth. Diaspora has high willingness to pay. | IFCT 2017 food data, IDRS calibration, English + Hindi + Urdu |
| **Wave 3 (Month 9–15)** | Gulf states (UAE, Saudi, Qatar), Malaysia, Indonesia, Egypt | Very high T2D prevalence, strong paid-app markets, Halal/Ramadan features already built | Arabic + Bahasa, RTL layout, MENA food pack |
| **Wave 4 (Month 15–24)** | USA, UK, Canada, Australia | Highest revenue per user, but highest regulatory + competitive intensity. Enter only *after* the clinician mode is regulatory-cleared or scoped out (see §3.5). | FDA/UKCA/TGA assessment, USDA + McCance food data, HIPAA-grade infra |
| **Wave 5 (Month 24+)** | EU, Latin America, Sub-Saharan Africa, China | EU = MDR burden (see §3.5). LatAm/Africa = huge need, low ARPU, needs a different pricing model. | CE marking project, CIQUAL/FRIDA/regional food packs |

**Architectural implication:** everything region-specific must be a **content pack loaded at runtime**, never hardcoded. Food database, portion units, GI/GL table, risk calibration coefficients, units of measure, language, meal slot names, and safety thresholds are all per-region config. If a new country requires a code change, the architecture has failed.

---

## 2. Goals & Non-Goals

### 2.1 Product Goals (V1)

| ID | Goal | Success Metric |
|----|------|----------------|
| G1 | Give users a credible, explainable diabetes risk score | ≥70% of users complete the full risk assessment |
| G2 | Make meal logging take under 15 seconds | Median log time < 15s; ≥4 logs/day for active users |
| G3 | Recognise Bangladeshi meals from a photo | Top-1 accuracy ≥85% on 60+ common dishes |
| G4 | Drive behaviour change | 30-day D30 retention ≥25%; ≥3 days/week logging |
| G5 | Convert to paid | Trial→paid conversion ≥8% |

### 2.2 Explicit Non-Goals (V1)

These are **out of scope and must be actively blocked in the product**:

- ❌ **Not a diagnostic device.** The app never says "you have diabetes." It outputs a *risk estimate*.
- ❌ **No insulin dosing, no medication dose calculation, no medication changes.** (Apple Guideline 1.4.2 restricts drug dosage calculators to approved medical entities.)
- ❌ **No measuring blood glucose, blood pressure, or oxygen from the phone camera or sensors.** Apple explicitly prohibits apps that claim to measure blood glucose or blood pressure using only device sensors — this is an automatic rejection.
- ❌ **No type-1 diabetes management, no gestational diabetes management** in V1 (route these users to "consult your doctor" mode).
- ❌ **No CGM integration** in V1 (V2 candidate).
- ❌ **No aggressive / very-low-calorie dieting.** See §5.4.
- ❌ **Clinician mode is not clinical decision support.** The doctor sees *the patient's own data and the patient's own risk score*. The app never recommends a treatment, diagnosis, or triage decision *to the doctor*. See §3.6 — this single boundary is what keeps you out of medical-device regulation in most markets.
- ❌ **No profiles for under-18s in V1.** Child health profiles trigger COPPA (US) and GDPR Article 8, which is an entire separate compliance workstream. V2 at the earliest.
- ❌ **No creating a health profile for another adult without their consent.** Invitation-based only (§3.6).

---

## 3. Regulatory, Safety & Store-Approval Requirements

> **This section is non-negotiable. It is the difference between a shipped app and a rejected app.**

### 3.1 App Store / Play Store constraints

| Requirement | Implementation |
|---|---|
| Apple 1.4.1 — medical apps get extra scrutiny; accuracy claims must be backed by disclosed data + methodology, or the app is rejected | Ship a public "How our model works" page: datasets used, validation AUC, known limitations. Link it in-app and on the App Store listing. |
| Apple 1.4.1 — no measuring glucose/BP/temperature with device sensors | Camera is used **only** for food recognition. Never for vitals. Do not use words like "scan your health." |
| Apple 1.4.1 — remind users to consult a doctor | Persistent doctor-referral CTA on every risk result and diet plan screen. |
| Apple 1.4.2 — drug dosage calculators restricted | No dose features at all. |
| Apple 5.1.3 — health data cannot be used for advertising or data mining | No ads. No selling data. No third-party analytics SDK receives health fields. |
| Google Play Health apps policy | Declare health data in the Data Safety form; provide a privacy policy URL; no misleading medical claims. |
| Marketing copy | Never use: *diagnose, cure, treat, reverse, medically accurate, clinically proven* — unless you actually have the clearance. Use: *estimate, screen, risk, guide, track, support.* |

### 3.2 Mandatory in-app disclaimers

**On first launch (blocking, must tap to accept):**

> Bye Bye Diabetes gives lifestyle and risk information. It is **not a medical device** and does **not diagnose or treat** any condition. Its estimates can be wrong. Always talk to a registered doctor before changing your diet, exercise, or any medication. If you take insulin or diabetes medication, do not change your dose based on this app.

**Persistent footer on the Risk Result screen:**
> This is a statistical estimate, not a diagnosis. Only a blood test ordered by a doctor can confirm diabetes.

Both must be available in **Bangla and English**.

### 3.3 Red-flag safety interceptor (build this as a shared service)

Any of the following triggers a **blocking safety card** that replaces the normal AI response and shows emergency guidance + a "Find a doctor" CTA:

| Trigger | Action |
|---|---|
| User-entered fasting glucose > 13.9 mmol/L (250 mg/dL) or random > 16.7 mmol/L (300 mg/dL) | "These numbers are high. Contact a doctor today." |
| User-entered glucose < 3.9 mmol/L (70 mg/dL) | Hypoglycaemia card: take 15g fast carbs, recheck in 15 min, contact doctor. |
| Free-text mentions: chest pain, unconsciousness, confusion, vomiting + can't keep fluids down, fruity breath, foot ulcer/black toe, sudden vision loss | Urgent-care card. No AI-generated advice. |
| Free-text mentions self-harm or suicidal thoughts | Crisis-support card with helpline info. Suppress all coaching content. |
| Pregnancy declared | Switch to "consult your doctor / obstetrician" mode; disable calorie deficit targets entirely. |
| Age < 18 declared | Block the risk model and diet planner; show a "this app is for adults 18+" screen. Set the App Store age rating accordingly. |

### 3.4 Data protection

- Health data is **encrypted at rest** (SQLCipher on device, AES-256 at DB level in cloud) and **in transit** (TLS 1.3, cert pinning).
- Data minimisation: photos used for calorie estimation are processed and **not retained on the server** unless the user opts into "help improve the model."
- Full **export** (JSON + PDF) and full **delete account** flow — required by Play Store policy and good practice under Bangladesh's data protection direction, GDPR (diaspora users), and Apple's privacy rules.
- No health data in push notification bodies. ("Time to log lunch" — not "Your glucose is high.")

---

### 3.5 International regulatory matrix

> **Read this before you write the clinician feature.** Going international is not a translation project. It is a regulatory project. Two markets in particular will decide your architecture: the **EU** and the **US**.

#### The core question: are you a medical device?

The answer depends almost entirely on your **stated intended purpose** and **who the output is aimed at** — not on your code.

| Jurisdiction | Where you stand | Practical implication |
|---|---|---|
| **🇧🇩 Bangladesh, 🇵🇰 Pakistan, most of Asia/Africa** | No mature SaMD regime for wellness apps | Lowest friction. Launch here first. Store guidelines (§3.1) are your real gatekeeper. |
| **🇺🇸 USA (FDA)** | 🟢 Favourable, and recently more so | FDA revised its **General Wellness** and **Clinical Decision Support** guidances in January 2026 in a distinctly deregulatory direction — sensor-based wearables and certain prediction software can sit outside device regulation provided they are intended solely for wellness, pose minimal risk, and **avoid disease, diagnostic, or clinical-management claims**. FDA also signalled enforcement discretion for software producing a single clinically appropriate recommendation, so long as it isn't for time-critical decisions. **But:** for CDS aimed at healthcare professionals, FDA now expects clear, accessible documentation explaining how the software works — the more your model is a black box to the doctor, the more likely FDA treats it as a device. → Your §3.1 "How our AI works" page becomes a *regulatory artefact*, not marketing. |
| **🇺🇸 USA (privacy)** | ⚠️ | Direct-to-consumer is generally **not HIPAA**, but the **FTC Health Breach Notification Rule** does apply to health apps. The moment a clinic pays you and you handle their patients' data, you likely become a **HIPAA Business Associate** and need a BAA, audit logs, and HIPAA-grade infrastructure. State laws (California CMIA/CPRA, Washington My Health My Data Act) add more. |
| **🇬🇧 UK (MHRA)** | 🟡 | UKCA marking regime, broadly MDR-like. Assess before Wave 4. |
| **🇪🇺 EU (MDR)** | 🔴 **Hardest market. Plan for it; don't stumble into it.** | Under **MDR Annex VIII Rule 11**, software intended for *diagnosis, prevention, monitoring, **prediction**, **prognosis**, treatment or alleviation of a disease* is a medical device, and Rule 11 pushes most decision-support and monitoring software to **Class IIa or above** — which requires a **Notified Body**, ISO 13485 QMS, IEC 62304 lifecycle, and clinical evaluation. The 2025 revision of MDCG 2019-11 brought prognosis/prediction software more explicitly into scope, generally at IIa or higher. Worse: **Class IIa+ devices embedding AI are generally treated as high-risk AI systems under the EU AI Act**, so the two regimes stack. A December 2025 Commission proposal to amend Rule 11 is in progress but not settled — do not build a plan on it landing. |
| **🇨🇦 Canada / 🇦🇺 Australia** | 🟡 | Health Canada SaMD framework / TGA. Moderate. Assess at Wave 4. |
| **🇮🇳 India** | 🟡 | CDSCO SaMD rules are evolving; **DPDP Act 2023** governs the data. |
| **🇦🇪🇸🇦 Gulf** | 🟡 | SFDA (Saudi) and UAE MOHAP registration for health apps; data-residency requirements in Saudi. |

#### The strategy that keeps you non-device

Build **one product with two clearly separated intended purposes**, and write them down formally:

```
CONSUMER MODE (all markets, Wave 1+)
  Intended purpose: "General wellness. Helps users maintain a healthy
  lifestyle by tracking diet and activity and providing lifestyle
  information. Not intended to diagnose, treat, cure, mitigate or
  prevent any disease."
  → Language: "risk factors", "lifestyle score", "wellness insight"
  → NEVER: "predicts your diabetes", "screening", "diagnosis", "prevents diabetes"

CLINICIAN MODE (gated, B2B, Wave 2+ in low-friction markets only)
  Intended purpose: "A record-keeping and data-visualisation tool that
  displays a patient's self-reported diet, activity and vitals to a
  clinician of the patient's choosing. All clinical interpretation and
  all target-setting is performed by the clinician."
  → The app shows DATA. The doctor makes DECISIONS.
  → The app never recommends a diagnosis, treatment or triage to the doctor.
  → Full methodology transparency so the HCP can independently review
    the basis of anything shown (this is the FDA CDS criterion).
```

**Concrete rules that follow from this:**

1. In consumer mode the risk output is framed as a **lifestyle risk-factor score**, not a disease prediction, in regulated markets. Ship this as a **per-region string pack** — Bangladesh can say "diabetes risk"; the EU build says "metabolic health score". Same model, different intended purpose, different words.
2. **Do not ship clinician mode in the EU** without a Notified Body engagement. Region-gate the feature flag.
3. Every clinician-facing screen exposes the "how this number was produced" link inline, one tap away.
4. Keep a **regulatory intended-purpose document** under version control alongside the code. When you change a feature, you change that document. This is what a reviewer or an auditor asks for first.
5. Budget realistically: a Class IIa CE marking project is typically **12–24 months and six figures**. Treat the EU as a Series-A-funded expansion, not a v1 checkbox.

> ⚠️ I am not a lawyer and this is not legal advice. Before Wave 3, retain a regulatory consultant for each target region. The cost of getting this wrong (forced delisting, fines, or an injury claim) is far higher than the consultation fee.

#### Data protection matrix

| Region | Regime | Key requirements |
|---|---|---|
| EU/UK | GDPR / UK GDPR | Health data = **special category** (Art. 9): explicit consent, **DPIA mandatory**, EU data residency, appointed representative, right to erasure, 72-hour breach notification |
| USA | FTC HBNR, state laws (CPRA, MHMDA), HIPAA if B2B | Breach notification, opt-in consent for sharing, BAA for clinic customers |
| India | DPDP Act 2023 | Consent manager, data-principal rights, local processing expectations |
| Canada | PIPEDA | Meaningful consent, breach reporting |
| Australia | Privacy Act + My Health Record rules | |
| Saudi / UAE | PDPL / UAE data law | **Data residency** — may require in-region hosting |
| Bangladesh | Evolving data protection framework | Track the current draft; follow GDPR as the safe superset |

**Architectural answer:** build **multi-region data residency** from day one — `eu-west`, `us-east`, `ap-south`, `me-central` — with the user's home region stamped on the account at signup and never silently migrated. Retrofitting residency is a rewrite; designing for it costs you a week.

### 3.6 Multi-profile consent & safeguarding rules

Multi-profile is where health apps get sued. These rules are mandatory:

| Rule | Why |
|---|---|
| **An adult's health profile can only be created by that adult, or created by invitation and *claimed* by them.** A family manager can send an invite; the invitee installs, logs in, and grants access. | Creating a permanent health record about another competent adult, under someone else's control, without their consent is unlawful in most jurisdictions. |
| **Every access grant is explicit, scoped, and time-boundable.** The patient chooses: view-only / view + set targets / full. | GDPR data-subject rights; basic dignity |
| **Revocation is one tap and immediate.** Visible in Settings → "Who can see my data". | Domestic-abuse and coercive-control risk is real in health apps. |
| **Full audit log, visible to the patient.** "Dr. Rahman viewed your glucose log on 12 Aug." | Trust + regulatory evidence |
| **Clinicians must be verified before receiving any patient data.** Licence number + document upload + manual human review + periodic re-verification. | An unverified "doctor" role is a data-harvesting vector. This is the highest-risk surface in the whole product. |
| **Managed (dependent) profiles are for people who genuinely cannot self-manage** — e.g. an elderly parent — and require a recorded attestation of the relationship plus, where possible, the dependent's own confirmation. | |
| **A clinician cannot bypass the §5.4 safety rails.** They can override *within* a widened band, with a mandatory reason field, an audit entry, and a notification to the patient. Absolute floors remain absolute. | A wrong number typed once shouldn't be able to starve a patient. |
| **No cross-profile data leakage.** Row-level security keyed on `profile_id`, enforced in the database, not just the app layer. Test this adversarially. | |
| **Under-18 profiles blocked in V1** (see §2.2). | COPPA / GDPR Art. 8 |

---

## 4. Target Users

### Persona 1 — "Ashraf, 44, worried but undiagnosed" (Primary)
Bank officer in Dhaka. Father had diabetes. Belly fat, sedentary desk job. Has never done a fasting glucose test. Wants to know: *am I in danger, and what do I eat instead of three plates of rice?*
**Needs:** Fast risk check without a lab test. Concrete "eat this instead" swaps in local food.

### Persona 2 — "Nasrin, 52, newly diagnosed T2D" (Primary)
Diagnosed 6 months ago, on metformin. Her doctor said "control your diet" and gave a photocopied chart she doesn't understand.
**Needs:** Daily plate guidance, portion size in বাটি/চামচ, a log she can show her doctor at the next visit.

### Persona 3 — "Tanvir, 29, prediabetic and gym-curious" (Secondary)
Wants a step counter, calorie tracking, and to lose 8kg.
**Needs:** Fitness features that keep him in the app daily.

### Persona 4 — "Sabrina, 34, the family health manager" (Primary — new in v2)
Works in Dubai, sends money home. Her mother (58, T2D) and father (62, prediabetic) both live in Chittagong. Her mother is not comfortable with apps. Sabrina wants to set up their profiles, see whether her mother is logging meals, and get an alert if something looks wrong.
**Needs:** Multi-profile switcher, a simple "how is Ma doing this week" digest, remote nudges. **She is the payer for three seats.**
> ⚠️ Note the tension: Sabrina wants oversight; her mother has a right to privacy. The invite-and-claim model in §3.6 resolves this — Ma grants Sabrina access, and can revoke it.

### Persona 5 — "Dr. Rahman, endocrinologist" (Primary — new in v2)
Sees 40 patients a day, 6 minutes each. Currently gets handwritten food diaries that are useless. Wants to set a carb target for a patient and see, at the next visit, whether they actually followed it.
**Needs:** Patient roster, invite-by-QR, per-patient 30-day view, ability to set targets, printable summary. **He is the B2B customer and your cheapest acquisition channel** — one endocrinologist can onboard 200 patients.
**Does NOT need and must not get:** the app telling him what to prescribe.

### Persona 6 — "Miguel, 47, São Paulo" (Wave 5)
Represents the international consumer. Different food, same disease, same needs. He is the reason §1.2's content-pack architecture matters.

---

## 5. Core Product Principles

1. **Estimate, never diagnose.** Every number is shown with a confidence range, not false precision. "≈ 520–640 kcal", not "573 kcal".
2. **Explainable by default.** Every risk score shows the top 3–5 contributing factors. A black-box percentage destroys trust and violates Apple 1.4.1's methodology-disclosure requirement.
3. **Deshi-first.** Bangla food names, local portion units, local price-aware food swaps (suggesting quinoa to a Dhaka user is a failure).
4. **Safe by construction.** Calorie targets have hard floors (see §5.4). No fasting challenges. No weight-loss competitions.
5. **Doctor-adjacent, not doctor-replacing.** The most valuable output is the report the user shows a real doctor.

### 5.4 Nutrition safety rails (hard-coded, not AI-decided)

| Rail | Rule |
|---|---|
| Minimum daily calories | Never recommend below **1200 kcal/day for women, 1500 kcal/day for men**. |
| Maximum deficit | Max 500 kcal/day below TDEE. Max recommended weight loss 0.5–1 kg/week. |
| BMI floor | If BMI < 18.5, disable weight-loss mode entirely; switch to maintenance/gain. |
| Disordered eating detection | If a user repeatedly logs < 800 kcal/day, or sets an unrealistic goal weight (BMI target < 18.5), show a supportive card and disable aggressive targets. Never gamify restriction. |
| Macro guidance | Follow standard T2D-friendly guidance: emphasise fibre, lower glycemic load, distributed carbs. No keto/extreme protocols pushed by default. |
| Medical conditions | If user declares CKD, heart failure, or pregnancy → disable auto diet plan, show doctor referral. |

---

## 6. Feature Specifications

### F1 — Onboarding & Health Profile

**Flow:** Splash → Language (বাংলা / English) → Value prop (3 cards) → Disclaimer (blocking accept) → Account creation → Health profile wizard → Risk assessment → Result → Paywall.

**Health profile fields:**

| Field | Type | Required | Notes |
|---|---|---|---|
| Age | int | ✅ | Block if < 18 |
| Sex at birth | enum | ✅ | Needed for BMR/risk |
| Height | cm | ✅ | |
| Weight | kg | ✅ | |
| Waist circumference | cm | ✅ | **Critical for South Asians** — see §7.1 |
| Family history of diabetes | enum: none / 2nd-degree / parent-sibling | ✅ | |
| Physical activity level | enum: sedentary → very active | ✅ | |
| Smoking | bool | ✅ | |
| Known high blood pressure | bool | ✅ | |
| On BP medication | bool | ✅ | |
| History of high blood glucose | bool | ✅ | |
| Gestational diabetes history | bool | conditional | Female only |
| Existing diabetes diagnosis | enum: no / prediabetes / T2D / T1D / gestational | ✅ | Routes the whole app experience |
| Optional lab values | fasting glucose, HbA1c, HDL, triglycerides, BP | ❌ | Unlocks the "high-confidence" model tier |

**Acceptance criteria:**
- Wizard is ≤ 8 screens, progress bar visible, all fields resumable.
- Waist measurement screen includes an illustrated "how to measure" guide.
- Every screen has a "Why do we ask?" tooltip.

---

### F2 — Diabetes Risk Assessment (the hero feature)

**Two tiers:**

- **Tier 1 — Screening (no lab required).** Uses questionnaire + anthropometry only. Output: risk band + percentage range. This is what most users get.
- **Tier 2 — High confidence (lab values entered).** Uses glucose/HbA1c/lipids. Output: narrower estimate + a clear statement of what the labs already indicate.

**Output UI:**
- A **risk band** (Low / Moderate / High / Very High) as the headline — bands are more honest than a fake-precise percentage.
- A **range**: "Your estimated 10-year risk is 18–26%."
- **Top contributing factors** (SHAP-derived, plain language): "Waist circumference (102 cm) — biggest factor", "Family history — father", "Low physical activity."
- **Modifiable vs non-modifiable** split. Age and family history go in a separate "can't change" section so the user isn't demoralised.
- **"What if" simulator:** slider for weight / waist / activity → live-updating risk. This is the single most engaging screen in the app; make it excellent.
- **CTA:** "Get a fasting glucose test" with a checklist of what to ask the doctor.

**Recompute triggers:** monthly, on weight change > 2kg, on new lab entry, on user request.

**Acceptance criteria:**
- Result renders in < 2s.
- Risk is never shown without the disclaimer footer.
- SHAP explanations are precomputed/cached, never blocking the UI.

---

### F3 — Camera Meal Logging (AI calorie estimation)

**Flow:** Tap camera → capture (with optional reference-object prompt) → on-device segmentation → detected items list → user confirms/edits each item and portion → save.

**Critical design decision: the user always confirms.** The AI proposes; the human disposes. This is what makes the accuracy claim defensible under Apple 1.4.1 and what saves you when the model misfires.

**Screen elements:**
1. Camera with a subtle plate-fit overlay and a hint: "Include a spoon or your thumb for better size estimate."
2. Detected items as editable chips: `ভাত (Rice) — 1.5 কাপ ≈ 300g` with `+ / −` steppers.
3. "Add missing item" search (falls back to F4 database).
4. Estimated totals with a **range**, not a point value: `≈ 620–780 kcal`.
5. Confidence badge: High / Medium / Low. Low confidence forces manual portion entry.
6. **Glycemic load indicator** — a coloured bar. This is your diabetes-specific differentiator that no generic calorie app has.

**Portion units must be local:** কাপ, বাটি, চামচ, পিস, টুকরা, হাতা — with gram equivalents based on standardised Bangladeshi serving guidelines.

**Acceptance criteria:**
- Photo → suggestion in < 3s on a mid-range Android device.
- Works offline (on-device model) with cloud fallback for hard cases.
- Photos never uploaded unless the user opted into model-improvement.
- Every calorie number displayed as a range with an "estimate" label.

---

### F4 — Manual Food Logging & Food Database

- Search in **Bangla and English** (`মুরগির ঝোল` and `chicken curry` both work), with transliteration tolerance ("murgir jhol").
- **Recent / Frequent / Favourites** tabs — 80% of logging is repeat meals; make repeats one tap.
- **"Log same as yesterday"** shortcut.
- Barcode scanner for packaged goods (V1.1).
- Custom foods and custom recipes (user enters ingredients once, reuses).
- Meal slots: Breakfast / Lunch / Dinner / Snack / সেহরি / ইফতার (Ramadan-aware).
- Water intake tracker.

**Food record fields:** name_bn, name_en, serving_units[], grams_per_unit, kcal, carbs, protein, fat, fibre, sugar, sodium, glycemic_index, glycemic_load_per_serving, source, is_verified.

---

### F5 — Daily Plan & Smart Suggestions

**Daily targets computed as:**
1. BMR via **Mifflin-St Jeor**.
2. TDEE = BMR × activity factor.
3. Goal adjustment (capped per §5.4).
4. Macro split: carbs 45–50%, protein 20–25%, fat 25–30%, fibre ≥ 25–30g/day — tuned toward lower glycemic load for prediabetic/T2D users.

**The "adjust my plate" engine (this is the feature the user asked for):**

After each logged meal, and at end of day, the system produces concrete gram-level adjustments:

> আজ আপনি ৩২০ গ্রাম ভাত খেয়েছেন। ৮০ গ্রাম কমিয়ে তার জায়গায় ১০০ গ্রাম সবজি নিন — এতে ~১০০ ক্যালরি কমবে এবং glycemic load ৩৫ থেকে ২৪-এ নামবে।

**Implementation: rules + constrained optimisation, NOT a free-form LLM.**

```
Given: today's logged intake, targets, user's food history, local food DB
Solve:  minimise |intake - target| for kcal, carbs, GL
Subject to: protein >= floor
            fibre  >= floor
            swaps drawn only from foods the user has eaten before
                  or from a curated deshi-alternatives list
            no swap that violates declared allergies/dislikes/halal
Output: max 3 suggestions, each with a gram delta and a stated reason
```

An LLM may be used **only** to phrase the output in natural Bangla/English — never to invent the numbers.

**Deshi swap table (seed data example):**

| Instead of | Try | Why |
|---|---|---|
| সাদা ভাত (white rice) | লাল চালের ভাত / ঢেঁকিছাঁটা চাল | Lower GI, more fibre |
| ২ পিস পরোটা | ২টি আটার রুটি | ~180 fewer kcal, less oil |
| চিনি দেওয়া চা | চিনি ছাড়া / কম চিনি | Direct sugar reduction |
| ভাজা মাছ | ঝোল/ভাপা মাছ | Less oil, same protein |
| মিষ্টি (1 pc) | টক দই + ফল | Much lower GL |

**Acceptance criteria:**
- Suggestions reference only foods available and affordable in Bangladesh.
- Never more than 3 suggestions at a time (choice overload kills action).
- Suggestions respect the safety rails in §5.4 before rendering.

---

### F6 — Activity & Fitness Tracking

- **Step counter** — CoreMotion (iOS) / Health Connect + `TYPE_STEP_COUNTER` sensor (Android). Must work with the app closed.
- **Distance (km)** and **active calories burned**.
- **Workout logging**: walking, running, cycling, gym, swimming, household work. Manual duration + intensity.
- **GPS walk/run tracking** with route map (V1.1).
- **Integrations:** Apple HealthKit (read/write steps, weight, workouts) and Android Health Connect. Also read weight from smart scales via these hubs.
- **Daily activity ring** + weekly streak.
- Sedentary nudge: "You've been sitting 2 hours — 5 min walk after meals lowers post-meal glucose."

**Acceptance criteria:**
- Background step counting drains < 3% battery/day.
- Steps reconcile with the native Health app within ±3%.
- HealthKit permission requested contextually with a clear explanation, never on first launch.

---

### F7 — Glucose, Weight & Vitals Log

- **Manual entry** of blood glucose (mmol/L and mg/dL toggle), tagged: fasting / pre-meal / 2h post-meal / random / bedtime.
- HbA1c entry with date.
- Weight, waist, blood pressure entries.
- **Trend charts** with target bands shaded.
- **Post-meal pairing:** if a glucose reading is entered 1.5–2.5h after a logged meal, pair them and show "this meal raised your glucose by X" — this is the app's most powerful teaching moment.
- Reminder scheduling for testing times.

> ⚠️ All values are **user-entered from their own glucometer or lab report**. The app never derives them from sensors.

---

### F8 — Insights & Doctor Report

- Weekly insight cards: "Your average lunch GL dropped 18% this week."
- Pattern detection: highest-GL meals, most frequent overshoot times, weekend vs weekday.
- **Doctor Report (PDF export)** — the killer retention/virality feature:
  - 30-day glucose log table
  - Weight & waist trend
  - Average daily kcal, carbs, fibre
  - Medication adherence (if tracked)
  - Risk score history
  - Clean, printable, clinic-friendly, with the disclaimer footer.
- Shareable via WhatsApp/email/print.

---

### F9 — Reminders & Notifications

| Type | Default | Configurable |
|---|---|---|
| Meal logging reminder | 3×/day at user's meal times | ✅ |
| Water reminder | Off | ✅ |
| Glucose test reminder | Off | ✅ |
| Medication reminder | Off (simple reminder only — **no dosing logic**) | ✅ |
| Move reminder | 2×/day | ✅ |
| Weekly insight | Sunday 8pm | ✅ |
| Streak at risk | 9pm if no log | ✅ |

Notification bodies must never contain health values (§3.4).

---

### F10 — AI Coach (chat assistant)

A conversational assistant for questions like "আমি কি আম খেতে পারব?" or "why is my morning sugar high?"

**Guardrails (implement as a system prompt + server-side filter + output validator):**
- Never gives medication or dose advice → deflects to doctor.
- Never diagnoses.
- Never contradicts the safety rails in §5.4.
- Runs every user message through the §3.3 red-flag interceptor **before** reaching the model.
- Cites the app's own logged data where relevant ("your last 5 breakfasts averaged 82g carbs").
- Answers in the user's chosen language, including natural Banglish.
- Rate-limited; premium-gated.

---

### F11 — Monetization

**Pricing must be purchasing-power-adjusted per market.** A single global USD price kills you in South Asia and leaves money on the table in the US. Use store price tiers per region.

| Tier | BD | US/EU | Includes |
|---|---|---|---|
| Free | ৳0 | $0 | 1 profile, manual logging, step counter, 1 risk assessment, basic food DB |
| **Premium Monthly** | ৳299 | $9.99 | 1 profile: camera calorie AI, daily check-in + trajectory, daily plan, AI coach, doctor report, insights |
| **Premium Yearly** | ৳2,499 | $69.99 | Same, ~35% saving |
| **Family (v2)** | ৳499/mo, ৳3,999/yr | $16.99/mo, $119/yr | **Up to 5 profiles**, household dashboard, weekly family digest |
| **+ Extra seat** | ৳99/mo | $3.99/mo | Beyond 5 |
| **Clinic (v2, B2B)** | ৳2,000/clinician/mo | $49/clinician/mo | Roster, target setting, branded reports, DPA/BAA, priority support. Volume discounts at 10+ seats. |
| Lifetime | ৳6,999 | $199 | Optional launch offer, single profile |

**Why Family is the strategic tier:** diabetes clusters in families — it's the strongest single risk factor in your own model. Someone worried about their own risk almost always has a parent or sibling with the disease. Family is your highest-margin, lowest-churn, most defensible tier, and it turns one diaspora payer into five active users. **Push it hard in onboarding**, right after the risk result names "family history" as a top factor: *"Your father's diagnosis raises your risk. Want to check his too?"*

**Clinic tier is your distribution engine**, not your revenue engine. One endocrinologist onboarding 200 patients is worth far more than $49/month. Consider making the clinician seat **free** in Wave 1–2 markets and monetising only the patients.

- 7-day free trial on yearly.
- **Local payment matters:** for the Bangladesh market, evaluate bKash/Nagad via web checkout for a "pro code" flow — but note both stores require IAP for in-app digital goods. Keep store IAP as the in-app path; use web-only purchase carefully and within current store rules.
- Paywall placement: after the first risk result (peak motivation), not before.
- **No ads. Ever.** (Apple 5.1.3 forbids using health data for advertising, and ads on a health app destroy trust.)

---

### F12 — Settings, Privacy & Account

Profile edit · Units (kg/lb, mmol/L / mg/dL, cm/in) · Language · Notification prefs · Dietary prefs (vegetarian, halal, allergies, dislikes) · Connected apps (HealthKit/Health Connect) · **Export my data** · **Delete my account** · Privacy policy · "How our AI works" (required by §3.1) · Support contact.

---

### F13 — Localisation

- Full **Bangla** and **English** UI from day one. Bangla is the default when device locale is `bn`.
- Bangla numerals option (১২৩) in display.
- Ramadan mode: সেহরি/ইফতার meal slots, adjusted reminder schedule, and a **safety card** advising diabetic users to consult their doctor before fasting.
- Right font stack: Noto Sans Bengali / Hind Siliguri.

---

---

### F14 — Daily Health Check-in & Longitudinal Monitoring ⭐ *new in v2*

**The problem with v1:** the risk score was a photograph. A user took it once, saw "24%", and never engaged with it again. **The fix:** make risk a *movie*. A number that moves every day is a number people come back for.

#### F14.1 The Daily Check-in card

A single card on Home, dismissible, targeted at **under 30 seconds**. It is adaptive — it never asks for everything at once.

| Field | Frequency | Input |
|---|---|---|
| Weight | Weekly (or daily if user opts in) | Number pad / smart scale via HealthKit |
| Blood glucose | Only if the user has a meter | Number + context tag |
| Energy level | Daily | 5-point emoji scale |
| Sleep hours | Daily | Slider (or auto from HealthKit/Health Connect) |
| Mood / stress | Daily | 5-point scale |
| Medication taken | Daily, if declared | Simple checkbox — **no dose logic** |
| Symptom toggles | Daily | Excessive thirst, frequent urination, blurred vision, tingling feet, unusual fatigue, slow-healing wounds |
| Water intake | Daily | Auto from F4 |
| Steps / activity | Automatic | From F6 |
| Waist | Monthly | Number pad |

**Adaptive logic:** rotate questions so the same user isn't asked identical things daily. If a field hasn't changed in 14 days, drop its frequency. If a symptom is toggled on, ask a targeted follow-up tomorrow.

#### F14.2 What the monitoring produces

1. **Risk trend line** — risk score over time, with annotations for what changed ("waist −4 cm since June").
2. **Trajectory badge:** `Improving ↓` / `Stable →` / `Worsening ↑`, computed from the delta in *modifiable* factors over a rolling 30/90-day window. This is the headline of the whole app.
3. **Streak & consistency score** — non-shaming. Missing a day shows "welcome back", never "you broke your streak."
4. **Anomaly detection** (statistical, not ML, in V1): flag when a rolling 7-day mean crosses a threshold — weight up >2kg in 2 weeks, fasting glucose trending up over 3 readings, average sleep below 5h for a week, three or more symptoms newly positive.
5. **Symptom escalation:** if the classic hyperglycaemia cluster (thirst + urination + fatigue + blurred vision) is toggled together for 3+ days, show a **non-alarming but firm card**: "These symptoms together are worth showing a doctor. Consider asking for a fasting glucose or HbA1c test." Never "you have diabetes."

#### F14.3 Safety additions for daily monitoring

- The §3.3 red-flag interceptor runs on **every** check-in submission.
- **Do not** show a rising risk number with alarm styling. Anxiety drives churn and, in a real patient, harm. Use neutral colour, add context ("this is normal week-to-week variation"), and always pair a rising trend with one concrete action.
- **Weight-anxiety guard:** if a user weighs in more than twice a day for 5+ days, gently reduce prompting and surface a supportive message. Do not encourage compulsive measurement.
- Missing days must never be penalised in a way that feels punitive.

**Acceptance criteria:**
- Check-in completable in ≤30s, ≤5 taps for the default set.
- Works fully offline; syncs when connected.
- Risk trend recomputes locally on-device on submit.
- All check-in prompts localised and region-configurable.

---

### F15 — Multi-Profile / Household Accounts ⭐ *new in v2*

**Model: one Account (billing + auth) → many Profiles (health records).**

This separation is the single most important architectural decision in v2. A Profile is a *person's health record* with its own history, targets, risk score, food log, and consent state. An Account is who pays and who logs in.

#### F15.1 Roles

| Role | Can do |
|---|---|
| **Owner** | Billing, invite/remove members, has their own profile |
| **Self-managed member** | Full control of their own profile; chooses who may see it |
| **Managed dependent** | Profile administered by an owner (elderly parent, someone who cannot self-manage); requires attestation per §3.6 |
| **Viewer** | Read-only access to a specific profile, granted by that profile |
| **Clinician** | Verified professional with scoped, revocable access to consented patient profiles (see F16) |

#### F15.2 Flows

**Adding a family member (invite-and-claim):**
```
Owner → Profiles → "Add family member"
  → enter name + relationship + email/phone
  → system sends invite link
  → invitee installs app, creates own login, completes own profile
  → invitee sees a consent screen: "Sabrina wants to view your
     health data. You can change this any time."
     [ Allow view ] [ Allow view + targets ] [ Decline ]
  → linked
```

**Adding a managed dependent (for people who genuinely can't self-manage):**
```
Owner → "Add dependent" → attestation checkbox (recorded, timestamped)
  → dependent profile created under owner's control
  → banner permanently visible on that profile: "Managed by Sabrina"
  → dependent can claim their own profile later at any time
```

#### F15.3 UX

- **Profile switcher** in the top-left avatar — Netflix-style, one tap, with a clear colour/avatar per person so nobody ever logs a meal to the wrong profile. **Log the active profile in the confirmation toast** ("Logged to Ma's diary") — mis-logging is the #1 usability failure of multi-profile health apps.
- Each profile has **fully independent**: risk score, calorie/macro targets, food log, activity, vitals, plan, streaks, AI coach context.
- **Household dashboard** (optional view): a card per person showing trend badge + last-logged time + any flags. Only shows what each person has consented to share.
- **Weekly family digest** notification: "Ma logged 5 of 7 days. Her average lunch GL is down 12%." Only with consent.
- Nudge feature: send an encouraging prompt to a family member. Rate-limited to prevent nagging/harassment.

#### F15.4 Pricing implication

Seats, not accounts. See updated §11.

**Acceptance criteria:**
- Row-level security keyed on `profile_id`, enforced in the DB. Adversarial test: attempt cross-profile read with a valid token for another profile → must fail.
- Profile switch is <300ms and visually unmistakable.
- Revoking access is immediate and reflected on the revoked party's device within one sync cycle.
- Deleting an account does not delete a self-managed member's profile — it unlinks it and offers them a standalone account.

---

### F16 — Clinician Mode & Patient Roster ⭐ *new in v2*

> ⚠️ **Build this last, gate it by region, and hold the line on §3.5.** The app shows the doctor **data**. The doctor makes the **decisions**.

#### F16.1 Clinician onboarding & verification

```
Sign up as clinician
  → professional details: name, licence/registration number,
    issuing body, country, specialty, institution
  → document upload (licence certificate, institutional ID)
  → MANUAL HUMAN REVIEW (SLA: 2 business days)
  → verified badge issued, re-verified every 12 months
  → separate signed agreement: acceptable use + data processing (DPA/BAA)
```
No patient data is accessible until verification completes. No exceptions. No "provisional access."

#### F16.2 Patient linking (patient-initiated, always)

- Clinician generates a **QR code / 6-digit clinic code**.
- Patient scans it in their app and sees an explicit consent screen naming the clinician, the clinic, and the exact data scope.
- Patient can revoke at any time from Settings → Who can see my data.
- Auto-expiry option (e.g. 12 months) with a re-consent prompt.

#### F16.3 Clinician workspace (web portal + mobile)

**Roster view:** searchable patient list with columns — name, last active, adherence %, trend badge, flags, next appointment. Sortable and filterable, so a doctor can find the 5 patients who need attention out of 200.

**Patient detail view:**
- 30/90-day glucose log with target bands
- Weight, waist, BP trends
- Nutrition summary: avg kcal, carbs, fibre, glycemic load, adherence to target
- Meal photos timeline (huge clinical value — doctors have never had this before)
- Risk score history + factor breakdown, with the methodology link inline
- Check-in history (energy, sleep, symptoms, medication adherence)
- Clinician's own private notes
- One-click PDF export

**Target setting (the doctor's main action):**
- Set daily kcal, carb grams, fibre floor, protein floor, goal weight, weight-change rate.
- Targets are attributed in the patient's app: **"Set by Dr. Rahman on 12 Aug"** — never presented as the app's own recommendation.
- Clamped by §5.4. Overriding beyond the normal band requires a mandatory free-text reason, generates an audit entry, and notifies the patient.
- Absolute hard floors cannot be overridden by anyone.

**Explicitly excluded:** medication or dose recommendations, diagnosis suggestions, triage or risk-stratification of the *roster*, any "you should do X for this patient" output. All of these convert the product into a regulated medical device.

**Messaging:** V1 → none (liability and expectation-setting nightmare: patients will send emergencies at 2am). V2 → asynchronous, clearly labelled non-urgent, with an automatic "for emergencies, call your local emergency number" banner and a documented response-time expectation.

#### F16.4 Clinic tier

Per-seat B2B pricing (see §11), org-level accounts, multiple clinicians per clinic, admin role, bulk patient invite, clinic-branded PDF reports, DPA/BAA on file.

**Acceptance criteria:**
- Unverified clinician accounts can access zero patient data — verified by automated test.
- Every patient-data read by a clinician writes an audit row visible to the patient.
- Clinician-set targets are visually attributed in the patient app.
- Clinician mode is behind a region feature flag, off by default in the EU.
- No screen in clinician mode contains a recommendation directed at the clinician.

---

## 7. AI / ML System Design

Three separate systems. Do not try to make one model do all of it.

### 7.1 Model A — Diabetes Risk Model (tabular)

**Task:** binary/ordinal classification → calibrated probability of prediabetes/T2D.

**Recommended architecture: hybrid, not pure ML.**

```
final_risk = calibrate( ensemble(
     w1 * validated_clinical_score,   # FINDRISC-style / IDRS-style, transparent
     w2 * gradient_boosted_model      # LightGBM/XGBoost on the datasets in §17
))
```

**Why hybrid:** a validated clinical score gives you defensibility with Apple reviewers and doctors; the GBM gives you accuracy. Publishing "we blend a validated risk score with an ML model trained on N records, AUC 0.8x on held-out data" is exactly the methodology disclosure Apple 1.4.1 demands.

**South Asian calibration — critical:**
- Standard BMI cutoffs under-detect South Asians. Use the **Asian-Pacific cutoffs: overweight ≥ 23, obese ≥ 27.5**.
- Use **waist circumference** (≥90 cm men, ≥80 cm women) as a first-class feature — it outperforms BMI in this population.
- Risk onset is roughly a decade earlier than in Western cohorts; do not blindly transplant an age curve trained on US data.

**Modelling requirements:**
- **Calibration is more important than accuracy.** Use isotonic regression or Platt scaling and report Brier score + calibration curve, not just accuracy. A 20% prediction must mean 20 out of 100.
- **Never report the inflated accuracy numbers you see in papers.** Many published "98% accuracy" diabetes models applied SMOTE *before* the train/test split — that leaks synthetic neighbours into the test set. Split first, resample only the training fold. Expect a realistic AUC of **0.78–0.86** for questionnaire-only models. That is a good model. Anything above ~0.95 on survey data means you have a bug.
- Class imbalance: use class weights or SMOTE-ENN **inside the training fold only**.
- Explainability: SHAP values exported at training time; map features to plain-language Bangla/English strings.
- Validate on a **held-out Bangladeshi dataset** even if you trained mostly on US data. Report both numbers.

**Deployment:** tiny model (<2MB) → **run on-device** (Core ML / TFLite). Zero latency, works offline, and the health data never leaves the phone — a genuine privacy selling point.

---

### 7.2 Model B — Food Recognition & Portion Estimation

This is the hard one. Break it into three sub-problems:

**B1. Segmentation + classification** — "what foods are on this plate?"
- Architecture: YOLOv8/v11-seg or a Segment-Anything-derived model fine-tuned on Bangladeshi food.
- Train on **FoodBD** (§17) — polygon-annotated, 67 classes, real Dhaka meals — plus Food-101/UEC-Food for general robustness.
- Target: top-1 ≥ 85% on your top 60 dishes.

**B2. Portion/mass estimation** — "how much?"
- This is where every app fails. Be honest: **even trained nutritionists average ~40% error estimating portions from images**, and the strongest published RGB-only models sit around 16–26% mean error.
- Practical approach for V1:
  1. Use LiDAR depth on supported iPhones; use ARCore depth on supported Androids.
  2. Fall back to a reference object (spoon, thumb, standard plate) with a coached capture UI.
  3. Final fallback: classify into **discrete portion buckets** (small / medium / large / X cups) rather than predicting continuous grams. Buckets are far more accurate and far more honest.
  4. **Always let the user correct the portion.** Their correction is your best training signal.
- Never display a single hard number. Always a range.

**B3. Nutrition lookup** — mass × per-100g composition
- Map recognised class → local food composition table (Food Composition Table for Bangladesh, INFS/University of Dhaka) → kcal, macros, fibre, GI, GL.
- GL = (GI × available carbohydrate in grams) / 100. Note that FoodBD computed GL using total food weight rather than available carbohydrate — recompute properly if you use their GL column.

**Alternative worth prototyping first:** a multimodal VLM (Claude/Gemini class) with a structured JSON output schema, given the photo + a curated list of candidate Bangladeshi dishes. This can beat a hand-trained model on breadth in week 1, at the cost of latency and per-call price. Recommended path: **VLM for launch → distil into an on-device model** once you have real user data and corrections.

---

### 7.3 Model C — Recommendation Engine

**Not a neural network.** As specified in F5: deterministic rules + constrained optimisation, with an LLM used only for natural-language phrasing. Reasons: auditable, safe, cheap, instant, and it can never hallucinate a number into a diabetic patient's meal plan.

---

### 7.4b Making Model A work internationally ⭐ *new in v2*

A model trained on US survey data and calibrated on Bangladeshi patients will be **miscalibrated** in Nigeria, Mexico, or Japan. Population prevalence differs, body-composition-to-risk relationships differ, and the same BMI means different things.

**Do NOT do this:** add `ethnicity` as a raw feature and let the gradient booster learn coefficients from whatever data you happen to have. That is how you ship a model that systematically under-diagnoses a group you had 200 samples of, and it is both an accuracy failure and a fairness/liability failure.

**Do this instead — a two-layer architecture:**

```
Layer 1: CORE MODEL (global, one model)
  Trained on pooled multi-country data.
  Features: age, sex, BMI, waist, waist-to-height ratio, family history,
            activity, smoking, BP, lipids, glucose (if available)
  Output: raw risk logit

Layer 2: REGIONAL CALIBRATION (per market, swappable config)
  - Anthropometric cutoffs per population
      (e.g. Asian-Pacific BMI 23/27.5 vs European 25/30;
       waist thresholds differ by population)
  - Prevalence prior from national/IDF data for that country
  - Isotonic recalibration fitted on local validation data
  Output: calibrated probability for THIS population
```

**Why this is better:** you add a country by shipping a config file and a validation set, not by retraining. It is auditable — you can show a regulator the calibration curve *for that market*. And you can honestly say "not yet validated for your region" and degrade to a transparent clinical score when you lack local data, instead of quietly guessing.

**Fairness requirements (non-negotiable at international scale):**
- Report AUC, sensitivity, specificity and calibration **per region, per sex, and per age band** — not just as a global average. A model at 0.84 overall can be at 0.61 for women over 60.
- Ship a **"validation status"** indicator per market: `Validated` / `Provisional` / `Not validated — showing general risk factors only`. Be honest in the UI. Users and regulators both reward this.
- Never launch a market where the model has never been validated on that population **without** downgrading to the transparent clinical-score-only mode.

**Waist-to-height ratio > BMI** as a cross-population feature. It travels far better across ethnicities than BMI does, and it's easy for a user to measure.

### 7.5 Model D — Trajectory / Longitudinal Model ⭐ *new in v2*

Daily check-ins (F14) create time-series data. But be honest about what you can and cannot do with it.

**The hard truth:** a genuine longitudinal risk model requires longitudinal *outcome* data — people tracked over years, some of whom develop diabetes. You will not have that on day one. Anyone claiming a "daily diabetes prediction" from three weeks of self-reported mood and step counts is selling something.

**Phased plan:**

**Phase 1 (V1 — ship this):** Deterministic trajectory, not ML.
```
Recompute the static Model A on updated inputs (weight, waist, activity, BP, glucose)
  → risk trend line over time
Trajectory badge = sign and magnitude of the change in MODIFIABLE factors
  over a rolling 30/90-day window, smoothed
Anomaly flags = statistical process control on rolling means
  (e.g. flag when a 7-day mean exits ±2σ of the personal 60-day baseline)
```
This is transparent, explainable, impossible to hallucinate, and genuinely useful. It answers "am I getting better?" — which is the question the user actually has.

**Phase 2 (V1.5):** Short-horizon *proxy* prediction. Instead of predicting diabetes, predict things you can actually verify within weeks:
- Post-meal glucose response from meal composition + personal history (verifiable within 2 hours — a fantastic teaching loop, and this is essentially the Zoe/DayTwo model)
- Next-week weight trajectory
- HbA1c estimate from logged glucose readings
These have short feedback loops, so you can measure your accuracy honestly and improve fast.

**Phase 3 (V2+, 18mo+):** Real longitudinal model, once your own cohort has produced outcomes (users who report a new diagnosis, or who upload a new HbA1c). Architecture: temporal GBM on windowed features, or a small GRU/Transformer over daily sequences. Bootstrap it with public longitudinal cohorts (§17.4).

**Cold-start rule:** show no trend until there are ≥14 days of data and ≥3 weigh-ins. Before that, show "building your baseline — keep logging" with a progress indicator. A trend line drawn from 3 points is a lie.

### 7.4 MLOps requirements

- Model versioning; every prediction stored with `model_version`.
- Feedback loop: log every user portion correction and every food misidentification (with consent) → weekly retraining candidate set.
- Shadow deployment: run new model alongside old, compare, then promote.
- Kill switch: remote config flag to disable AI features and fall back to manual logging if a model misbehaves in production.
- Monitor: inference latency p95, top-1 accuracy on a golden set, user correction rate (the single best real-world quality metric).

---

## 8. Data Model

> **v2 restructure:** `User` is split into `Account` (auth + billing) and `Profile` (a person's health record). Every health table now keys on `profile_id`, not `user_id`. Do this refactor before writing any feature code — retrofitting it later means touching every table and every query.

```
Account                          # who logs in and who pays
  id, email, phone, auth_provider, created_at,
  home_region(bd|in|ae|us|uk|eu|...), data_residency_zone,
  locale, units_prefs, subscription_status, subscription_expiry,
  seat_count, account_type(individual|family|clinic)

Profile                          # a person's health record
  id, account_id_owner, claimed_by_account_id(nullable),
  display_name, avatar_color, profile_type(self|member|dependent|patient),
  region_pack, is_managed, managed_attestation_at,
  created_at, archived_at

ProfileMembership                # who can see/do what on a profile
  id, profile_id, account_id, role(owner|self|viewer|editor|clinician),
  scope(view|view_targets|full), granted_at, granted_by,
  expires_at, revoked_at, revoked_by

CareRelationship                 # clinician ↔ patient
  id, clinician_account_id, profile_id, clinic_id,
  consent_granted_at, consent_scope, expires_at, revoked_at, status

ClinicianVerification
  account_id, licence_number, issuing_body, country, specialty,
  documents[], status(pending|verified|rejected|expired),
  verified_by, verified_at, expires_at

Clinic
  id, name, country, admin_account_id, seat_count,
  dpa_signed_at, baa_signed_at, branding_json

AccessAuditLog                   # every read/write on someone else's profile
  id, profile_id, actor_account_id, actor_role, action,
  resource, ip_hash, occurred_at, visible_to_patient(bool)

RegionPack                       # the internationalisation unit
  code, country, languages[], food_db_version, gi_table_version,
  bmi_cutoffs, waist_cutoffs, prevalence_prior,
  calibration_model_version, validation_status(validated|provisional|none),
  units_default, meal_slots[], safety_thresholds_json,
  clinician_mode_enabled(bool)

HealthProfile                    # clinical attributes, 1:1 with Profile
  profile_id, dob, sex, height_cm, weight_kg, waist_cm,
  activity_level, smoker, hypertension, on_bp_meds,
  family_history, diabetes_status, conditions[], allergies[],
  dietary_prefs[], goal_type, goal_weight_kg, updated_at

DailyCheckin                     # F14
  id, profile_id, date, weight_kg, energy_level, sleep_hours,
  mood, stress, meds_taken, symptoms[], water_ml, notes,
  completed_at, source(manual|healthkit|health_connect)

RiskTrajectory                   # F14.2 / Model D
  id, profile_id, window_start, window_end,
  risk_start, risk_end, delta, trajectory(improving|stable|worsening),
  drivers_json, model_version, computed_at

TargetOverride                   # F16.3 — clinician-set targets
  id, profile_id, set_by_account_id, kcal, carb_g, fibre_g,
  protein_g, goal_weight_kg, rate_kg_per_week,
  reason_text, is_beyond_default_band, set_at, expires_at,
  acknowledged_by_patient_at

RiskAssessment
  id, profile_id, taken_at, tier(1|2), inputs_json,
  risk_probability, risk_band, confidence_low, confidence_high,
  top_factors_json, model_version

FoodItem                        # master database
  id, name_bn, name_en, aliases[], category, per_100g{kcal,carb,protein,
  fat,fibre,sugar,sodium}, gi, serving_units[{unit_bn,unit_en,grams}],
  source, is_verified, image_url

MealLog
  id, profile_id, logged_at, meal_slot, entry_method(camera|manual|barcode|repeat),
  photo_hash, total_kcal, total_carb, total_protein, total_fat,
  total_fibre, total_gl, confidence, model_version

MealLogItem
  id, meal_log_id, food_item_id, grams, unit_used, unit_qty,
  kcal, carb, protein, fat, fibre, gl,
  ai_suggested(bool), user_corrected(bool)

ActivityLog
  id, profile_id, date, steps, distance_m, active_kcal, source(healthkit|
  health_connect|manual), workouts[{type,duration_min,intensity,kcal}]

VitalLog
  id, profile_id, recorded_at, type(glucose|hba1c|weight|waist|bp),
  value, unit, context_tag, note

Suggestion
  id, profile_id, created_at, type(swap|portion|activity),
  payload_json, shown, accepted

DailySummary                    # denormalised for fast charts
  profile_id, date, kcal_in, kcal_out, carb, protein, fat, fibre,
  total_gl, steps, water_ml, target_kcal, adherence_score
```

---

## 9. Recommended Tech Stack

| Layer | Choice | Rationale |
|---|---|---|
| Mobile | **React Native (Expo) + TypeScript** or **Flutter** | One codebase for both stores. RN if you want the JS ecosystem; Flutter if you want smoother custom UI. Native modules needed either way for HealthKit/Health Connect. |
| On-device ML | Core ML (iOS), TFLite / LiteRT (Android), ONNX Runtime Mobile | Risk model + food segmentation run locally |
| Backend | **Supabase** (Postgres + Auth + Storage + RLS) or Firebase | RLS gives you per-user data isolation cheaply — important for health data |
| ML API | Python FastAPI on Cloud Run / Railway | For the heavy vision fallback and VLM calls |
| Local DB | SQLite + SQLCipher (via WatermelonDB or Drift) | Offline-first is mandatory — Bangladesh network reality |
| Sync | Last-write-wins with per-record `updated_at` + conflict queue | |
| Payments | RevenueCat | Handles both stores' IAP, trials, receipts |
| Analytics | PostHog self-hosted or Amplitude with **health fields stripped** | Never send health data to third-party analytics (Apple 5.1.3) |
| Crash | Sentry (with PII scrubbing) | |
| Charts | Victory Native / fl_chart | |

**Offline-first is non-negotiable.** Logging, step counting, and the risk model must all work with zero connectivity.

---

## 10. API Surface (v1)

```
POST   /auth/signup                 POST /auth/login          POST /auth/refresh
GET    /me                          PATCH /me/profile

POST   /risk/assess                 → {risk_band, prob, range, top_factors[]}
GET    /risk/history

POST   /food/recognize              (multipart image) → {items[], confidence, totals}
GET    /food/search?q=&lang=        → paginated FoodItem[]
GET    /food/:id
POST   /food/custom

POST   /meals                       GET /meals?from=&to=      PATCH /meals/:id   DELETE /meals/:id
POST   /meals/:id/correct           → training feedback signal

POST   /activity/sync               GET /activity?from=&to=
POST   /vitals                      GET /vitals?type=&from=&to=

GET    /plan/today                  → {targets, consumed, remaining, suggestions[]}
POST   /plan/suggestions/:id/accept

POST   /coach/message               → guarded LLM response
GET    /insights/weekly
POST   /reports/doctor-pdf          → signed URL

GET    /export/all                  DELETE /account

# ── v2: profiles & consent ──────────────────────────────────────────
GET    /profiles                    → all profiles this account can access
POST   /profiles                    (self | dependent)
POST   /profiles/invite             → {invite_link, expires_at}
POST   /profiles/claim/:token       → invitee claims their own profile
PATCH  /profiles/:id
POST   /profiles/:id/grants         → grant access {account_id, scope, expires_at}
DELETE /profiles/:id/grants/:grantId → revoke (immediate)
GET    /profiles/:id/access-log     → patient-visible audit trail
GET    /household/digest            → weekly family summary (consented data only)
POST   /household/nudge             → rate-limited encouragement to a member

# ── v2: daily monitoring ────────────────────────────────────────────
POST   /checkins                    → {trajectory, flags[], next_prompt}
GET    /checkins?from=&to=
GET    /trajectory                  → {trend[], badge, drivers[], confidence}
GET    /checkins/today              → adaptive question set for this user

# ── v2: clinician ───────────────────────────────────────────────────
POST   /clinician/apply             → verification submission
GET    /clinician/status
GET    /clinician/patients          → roster {name, adherence, trend, flags}
GET    /clinician/patients/:pid     → full patient view (writes audit row)
POST   /clinician/patients/:pid/targets  → requires reason if beyond band
POST   /clinician/invite-code       → {qr_payload, code, expires_at}
GET    /clinician/patients/:pid/report
GET    /clinics/:id/members         POST /clinics/:id/members

# ── v2: internationalisation ────────────────────────────────────────
GET    /regions/:code/pack          → food db version, cutoffs, calibration
GET    /regions/:code/validation    → model validation status for this market
```

**Cross-cutting middleware (all v2 endpoints):**
- `resolveProfile` — every health request carries an explicit `profile_id`; the server verifies the caller's grant. **Never infer the profile from the session.**
- `auditAccess` — logs any access to a profile the caller does not own.
- `regionGate` — blocks region-disabled features (e.g. clinician mode in the EU).
- `residencyRouter` — routes to the account's data-residency zone.
- `redFlagInterceptor` — on `/checkins`, `/vitals`, `/coach/message`.

All endpoints: JWT auth, per-user rate limiting, request/response schema validation, and the §3.3 red-flag interceptor as middleware on `/coach/message` and `/vitals`.

---

## 11. User Flows (happy paths)

**Flow A — First risk check (target: < 4 minutes)**
Install → language → disclaimer → signup → 8-step profile → "Calculating…" (animated, ~3s) → Risk result with band + factors → "What if" simulator → paywall → home.

**Flow B — Log lunch by camera (target: < 15 seconds)**
Home → FAB camera → capture → items detected → confirm/adjust portions → save → toast: "620–780 kcal logged. GL 28 — a bit high. Tap for a swap."

**Flow C — Doctor visit prep**
Insights tab → "Doctor Report" → select date range → generate PDF → share to WhatsApp/print.

---

## 12. Screen Inventory (for Claude Design)

**Onboarding (8):** Splash · Language select · Value prop carousel · Disclaimer/consent · Sign up / log in · Profile wizard (4 sub-screens) · Waist measurement guide · Loading/calculating

**Core (5 tabs):** Home/Dashboard · Log (Diary) · Activity · Insights · Profile

**Home/Dashboard:** greeting, calorie ring (consumed/remaining), macro bars, glycemic-load meter, steps card, next-meal suggestion card, quick-log FAB, risk band chip.

**Risk:** Risk result · Factor breakdown · "What if" simulator · Risk history chart · "How our AI works" explainer

**Food:** Camera capture · Detection review/edit · Portion picker (deshi units) · Food search · Food detail · Custom food creator · Recipe builder · Meal diary day view · Water tracker

**Activity:** Activity dashboard · Step detail (hourly) · Workout log · Workout detail · GPS route map

**Vitals:** Glucose log list · Add glucose entry · Weight/waist entry · BP entry · Trend charts · Meal↔glucose pairing view

**Insights:** Weekly insight cards · Trends · Doctor report preview · PDF export sheet

**Plan:** Today's plan · Swap suggestions · Meal plan for tomorrow

**Coach:** Chat · Suggested prompts · Safety card variant

**Daily Check-in (v2):** Check-in card (Home embed) · Full check-in flow (3 adaptive steps) · Symptom picker · Trajectory detail (trend chart + drivers) · Streak/consistency view · Anomaly alert card · Baseline-building empty state

**Multi-Profile (v2):** Profile switcher sheet · Profiles list · Add family member (invite) · Add dependent (attestation) · Invite sent / pending state · **Consent screen (invitee side)** · Who can see my data · Access audit log · Household dashboard · Weekly family digest · Nudge composer · Managed-profile banner

**Clinician (v2 — web-first, mobile secondary):** Clinician signup · Verification upload · Verification pending / rejected states · Patient roster (sortable, filterable) · Patient detail (tabs: overview, nutrition, glucose, photos, check-ins, notes) · Set targets · Override reason modal · Invite QR / clinic code · Clinic admin · Clinician profile · Empty roster state

**System:** Paywall · Seat management · Subscription management · Settings · Notification settings · Connected apps · Privacy & data · Region & language · **Model validation status card** · Export data · Delete account · Empty states (×6) · Error states (×4) · Offline banner · Red-flag safety card

**~95 screens total.** Build order for Claude Design: core 5 tabs → risk → food → check-in → profile switcher → clinician portal last.

---

## 13. Design System Direction

- **Mood:** calm, clinical-but-warm. Trustworthy, not gamified-childish. This app handles a scary topic — over-cheerful design reads as unserious.
- **Palette:** deep teal/green primary (health, and culturally positive in Bangladesh), warm off-white surfaces, amber for caution, muted red reserved *only* for safety alerts. Never use red for "over your calories" — it shames.
- **Typography:** a humanist sans with strong Bangla support (Hind Siliguri / Noto Sans Bengali). Bangla and English must be visually balanced — Bangla should not look like an afterthought.
- **Data viz:** rings and area charts, generous whitespace, always show units. Ranges shown as bands, not lines.
- **Accessibility:** min 16sp body text (older users are a core demographic), AA contrast, full dynamic type support, VoiceOver/TalkBack labels on every chart.
- **Tone of voice:** encouraging, never scolding. "Let's balance dinner" not "You failed your target."

### 13.2 Internationalisation requirements ⭐ *new in v2*

Localisation is an architectural constraint, not a launch-week task.

| Requirement | Detail |
|---|---|
| **String externalisation** | Zero hardcoded user-facing strings from commit #1. ICU MessageFormat for plurals and gender. |
| **RTL support** | Arabic and Urdu are Wave 3. Retrofitting RTL is brutal — use logical properties (`start`/`end`, never `left`/`right`) from day one, and test with a pseudo-RTL locale in CI. |
| **Text expansion** | German runs ~35% longer than English; Bangla and Arabic have different line heights and ascenders. No fixed-height buttons. No text in images. |
| **Font stack per script** | Latin, Bengali (Hind Siliguri/Noto Sans Bengali), Devanagari, Arabic (Noto Naskh), Nastaliq for Urdu. Test that Bangla and Arabic don't look like afterthoughts next to Latin. |
| **Numerals** | Toggle for local numeral systems (১২ৣ, ١٢٣). Never assume Western Arabic numerals in display. |
| **Units** | kg/lb, cm/in, mmol/L vs mg/dL, kcal/kJ — per-region defaults, user-overridable. Store canonical SI in the DB, always. |
| **Dates & calendars** | Locale-aware formatting. Hijri calendar display option for Ramadan features. |
| **Meal slots** | Region-configurable: breakfast/lunch/dinner vs সেহরি/ইফতার vs merienda vs elevenses. Not an enum in code — config. |
| **Cultural food context** | Ramadan, Navratri and other fasting periods, festive-season modes. Each ships as region-pack content with an appropriate safety card for people with diabetes. |
| **Localisation ≠ translation** | Never machine-translate health copy unreviewed. Every safety string, disclaimer, and clinical term needs a native-speaking clinical reviewer per market. Budget for it. |
| **Currency & pricing** | Purchasing-power-adjusted per market via store price tiers, not a flat USD price. |

**Design system implication:** components must survive a 40% string expansion, a right-to-left flip, and a script with taller line heights, without any layout breaking. Build a `?pseudo=true` locale that does all three at once and run every screen through it in CI.

---

## 14. Success Metrics

| Category | Metric | V1 Target |
|---|---|---|
| Activation | Complete risk assessment | ≥70% |
| Engagement | DAU/MAU | ≥25% |
| Engagement | Meals logged/active user/day | ≥2.5 |
| Quality | AI food detection accepted without edit | ≥60% |
| Quality | Portion corrected by user | ≤40% |
| Retention | D7 / D30 | 40% / 25% |
| Revenue | Trial → paid | ≥8% |
| Revenue | 12-month churn | ≤45% |
| Health outcome | Users with ≥0.3% HbA1c drop at 6mo | Track from V1.1 |
| Trust | App store rating | ≥4.5 |
| **Monitoring (v2)** | Daily check-in completion rate | ≥45% of active users |
| **Monitoring (v2)** | Users with ≥14 days of check-ins (trend unlocked) | ≥50% of paid users |
| **Multi-profile (v2)** | Accounts with ≥2 profiles | ≥30% |
| **Multi-profile (v2)** | Invite → claimed conversion | ≥40% |
| **Multi-profile (v2)** | Family tier share of subscription revenue | ≥35% |
| **Multi-profile (v2)** | Churn, family vs single tier | Family churn ≤60% of single |
| **Clinician (v2)** | Patients onboarded per verified clinician | ≥25 in 90 days |
| **Clinician (v2)** | Clinician-referred patient D30 retention | ≥40% (should beat organic) |
| **International** | Markets with `Validated` model status | ≥4 by month 18 |
| **Safety** | Red-flag interceptor false-negative rate on golden set | 0 |

---

## 15. Roadmap

**Phase 0 — Foundations (Weeks 1–4)**
Datasets acquired and licensed · risk model trained + calibrated · BD food pack seeded (300+ items) · design system with i18n + RTL scaffolding · **Account/Profile schema locked** · region-pack architecture · architecture spike

**Phase 1 — MVP (Weeks 5–12)** — *Bangladesh*
Onboarding + profile · risk assessment (Tier 1) with explanations · manual food logging + search · step counter + HealthKit/Health Connect · daily targets · dashboard · **daily check-in card (F14.1)** · Bangla/English · paywall · internal beta

**Phase 2 — V1.0 Launch (Weeks 13–20)** — *Bangladesh*
Camera food recognition · portion estimation · swap suggestions · glucose & weight logging · **trajectory trend + badge (F14.2)** · insights · doctor PDF report · AI coach with guardrails · public BD launch

**Phase 3 — V1.5 (Months 6–9)** — *Family + South Asia*
⭐ **Multi-profile / Family tier (F15)** · household dashboard · invite-and-claim consent flows · access audit log · barcode scanner · recipe builder · Tier 2 risk (labs) · Ramadan mode · widgets · **India/Pakistan/Sri Lanka launch** (IFCT food pack, Hindi/Urdu, IDRS calibration) · diaspora markets

**Phase 4 — V2.0 (Months 9–15)** — *Clinician + MENA/SEA*
⭐ **Clinician mode + verification + patient roster (F16)** · web portal · clinic tier · target setting with audit · **Gulf/Malaysia/Indonesia launch** (Arabic, RTL, MENA food pack, data residency) · CGM integration (Libre/Dexcom) · BLE glucometer pairing · Apple Watch / Wear OS

**Phase 5 — V2.5 (Months 15–24)** — *Western markets*
FDA/UKCA/TGA regulatory assessment complete · HIPAA-grade infrastructure + BAA process · **US/UK/Canada/Australia launch** · USDA + McCance food packs · Phase-2 proxy prediction models (post-meal glucose response) · clinical validation study published

**Phase 6 — V3 (Months 24+)** — *EU + emerging*
CE marking project (Class IIa, Notified Body) if the business case holds · EU AI Act conformity · LatAm/Africa with a low-ARPU pricing model · China assessment · real longitudinal model trained on own cohort (§7.5 Phase 3)

> **Sequencing principle:** every phase adds *either* a new capability *or* a new market — never both at once. Shipping clinician mode and entering the US in the same quarter is how teams miss both.

---

## 16. Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| **App Store rejection under 1.4.1** | 🔴 Critical | Publish the methodology page; never claim diagnosis; add doctor reminders everywhere; get a Bangladeshi physician to review copy and let you name them as clinical advisor |
| **Portion estimation is inaccurate → users lose trust** | 🔴 High | Ranges not point values; confidence badges; user always confirms; portion buckets over continuous grams |
| **Risk model doesn't transfer to Bangladeshi users** | 🔴 High | Validate on DiaBD / local clinical data; use Asian BMI + waist cutoffs; fine-tune with local records |
| **Wrong advice harms a diabetic user** | 🔴 Critical | Hard safety rails (§5.4), red-flag interceptor (§3.3), no medication logic at all, LLM never generates numbers |
| **Health data breach** | 🔴 Critical | On-device-first architecture, encryption, RLS, no health data to analytics, penetration test before launch |
| **Local payment friction (bKash/Nagad not native to IAP)** | 🟡 Medium | RevenueCat + store IAP as primary; price yearly attractively; consider a web-purchase path only within current store rules |
| **Low willingness to pay in BD market** | 🟡 Medium | Aggressive local pricing; generous free tier; B2B2C via clinics and pharmacies; diaspora pricing tier |
| **Food DB incompleteness → users can't log** | 🟡 Medium | Seed 300+ items pre-launch; fast "add custom food"; crowdsource with verification queue |
| **Competitor (HealthifyMe etc.) enters BD properly** | 🟡 Medium | Move fast on the Bangla food moat; doctor relationships are defensible, code isn't |
| **EU MDR forces Class IIa on the whole product** | 🔴 Critical | Two separate intended-purpose documents (§3.5); region feature flags; consumer mode framed as general wellness; treat EU as a funded, scheduled project not an accident |
| **Unverified "clinician" harvests patient data** | 🔴 Critical | Manual human verification with document review; zero data access pre-verification; annual re-verification; audit log visible to patients; anomaly detection on bulk patient views |
| **Family member creates a profile for an adult who never consented** | 🔴 High | Invite-and-claim only (§3.6); dependent profiles require attestation + permanent banner; one-tap revocation; access log surfaced to the patient |
| **Multi-profile data leakage across profiles** | 🔴 Critical | DB-level row security on `profile_id`; explicit `profile_id` on every request, never session-inferred; adversarial cross-profile penetration tests in CI |
| **Wrong profile selected → user logs meals to the wrong person** | 🟡 Medium | Unmistakable colour/avatar per profile; profile name in every confirmation toast; confirm on switch |
| **Daily risk number creates health anxiety** | 🟠 High | Neutral styling on rising trends; always pair with one concrete action; smoothing and confidence bands; weight-anxiety guard (F14.3); no red alarm colours outside true safety events |
| **Model miscalibrated in a new market → systematic harm** | 🔴 High | Two-layer calibration (§7.4b); per-region + per-sex + per-age-band metrics; honest `Not validated` UI state that degrades to a transparent clinical score |
| **Clinician mode drifts into decision support** | 🔴 Critical | Written intended-purpose doc under version control; a review gate on every clinician-facing screen: *does this contain a recommendation aimed at the doctor?* If yes, cut it. |
| **Data residency violation in Gulf/EU** | 🟠 High | Multi-region infrastructure from day one; residency zone stamped at signup; no silent migration |
| **Scope explosion — three products at once** | 🟠 High | Strict phase gates (§15). Do not start clinician mode until family tier has shipped and stabilised. |

---

## 17. Appendix A — Dataset Recommendations

### 17.1 For the risk model (Model A)

**Tier 1 — Use these as your primary training corpus:**

| Dataset | Size | Why it matters | Caution |
|---|---|---|---|
| **DiaBD (Diabetes in Bangladesh)** — Mendeley, `10.17632/m8cgwxs9s6.2`, published in *Data in Brief* 2025 by United International University | **5,288 Bangladeshi patient records** | ⭐ **Your most important dataset.** Real Bangladeshi patients. Features: age, gender, pulse rate, systolic/diastolic BP, glucose, BMI, family history of diabetes/hypertension/CVD, binary diabetes label. This is what makes your model locally credible. | Modest size — use for validation and fine-tuning, not sole training |
| **CDC BRFSS Diabetes Health Indicators** (Kaggle, Alex Teboul's cleaned 2015 version) | **253,680 records**, 21 features | Huge, free, well-documented, lifestyle-feature-rich (BMI, activity, diet, smoking, BP, cholesterol, income, education). Perfect for pretraining a questionnaire-only model. A 2023-BRFSS version with ~433k responses also exists. | US population, self-reported by telephone → reporting bias; ~14% positive class, heavily imbalanced |
| **Type-2 Diabetes Dataset Bangladesh** — Mendeley `10.17632/rn9m3zb7nt.1` | 1,065 patients, ages 21–86 | Clinical measurements from Bangladesh: pregnancies, BMI, systolic/diastolic BP, diabetes pedigree function, insulin, skin thickness, glucose | Imbalanced the other way (840 diabetic vs 225 not); some missing diastolic BP and skin-fold values |
| **Bangladesh Demographic and Health Survey (BDHS) 2022** | Nationally representative | Gold-standard population-level data with measured fasting plasma glucose. Best source for calibrating your model to true Bangladeshi prevalence | Requires DHS Program registration and a data request |
| **Type-2 Diabetes (Pabna Diabetes Hospital)** — Mendeley `10.17632/vxnyysk9vc.2` | Hospital records, Bangladesh | Additional local clinical data, anonymised | Single-hospital selection bias |

**Tier 2 — Supporting:**

- **NHANES** (CDC) — has lab-confirmed HbA1c and fasting glucose, so labels are objective rather than self-reported. Best for training your Tier-2 (lab-based) model.
- **UCI Early Stage Diabetes Risk Prediction** (Sylhet Diabetes Hospital, 520 records) — symptom-based (polyuria, polydipsia, sudden weight loss). Bangladeshi origin. Good for a *symptom checker* feature, but too small and too symptom-heavy for primary risk prediction.

**Avoid / deprioritise:**

- ❌ **Pima Indians Diabetes Dataset** (768 rows). It is the most-used and most-misleading dataset in this space: tiny, from one specific Native American population, riddled with impossible zero values (zero insulin, zero blood pressure, zero BMI), and completely unrepresentative of Bangladeshi adults. Fine for a tutorial. Not fine for a paid health product.
- ❌ **Diabetes 130-US Hospitals** — that's a *hospital readmission* dataset, not a risk prediction dataset. Different problem.

**Recommended training recipe:**

```
1. Pretrain LightGBM on BRFSS (253k) — questionnaire features only
2. Fine-tune / recalibrate on DiaBD (5,288 Bangladeshi records)
3. Hold out a Bangladeshi test set — NEVER touch it during tuning
4. Split BEFORE any SMOTE/resampling (this is where most published
   papers cheat and get fake 98% accuracy)
5. Calibrate with isotonic regression; report Brier score + calibration curve
6. Blend with a transparent clinical score (FINDRISC-style, adapted to
   South Asian BMI/waist cutoffs)
7. Compute SHAP; export the top-factor mapping for the UI
8. Publish AUC, sensitivity, specificity, and known limitations
   → this page is what satisfies Apple Guideline 1.4.1
```

Expect real-world **AUC 0.78–0.86** for the no-lab tier and **0.85–0.92** with labs. Anything higher, look for leakage.

---

### 17.2 For food recognition & calorie estimation (Model B)

| Dataset | What's in it | Use it for |
|---|---|---|
| **FoodBD** — Mendeley `10.17632/xh3ghf3jbg.2`, published in *BMC Research Notes* 2026 (BUET + UIU + MBSTU) | ⭐ **3,523 smartphone photos of real Bangladeshi meals from Dhaka**, polygon-segmented across **67 food classes**, labels in **Bangla and English**, with **1,837 images carrying expert nutrition annotations** (carbohydrate, protein, fat, fibre, calorie, **glycemic load**). Pre-split 70/20/10. CC-BY licensed. It was originally built *specifically for dietary assessment of diabetic patients*. | **This is the single best dataset for your app.** Start here for segmentation + classification + nutrition mapping. |
| **Nutrition5k** (Google) | 5,000 dishes, 20k videos, overhead RGB + **depth**, ingredient-level mass/calorie/macro ground truth measured on a real scale | Training portion/mass regression, especially if you use LiDAR/ARCore depth. Note the honest benchmark: RGB-only ≈26% calorie error, RGB+depth ≈16.5% |
| **Food-101** | 101k images, 101 Western classes | General visual pretraining / backbone robustness |
| **UEC-Food 256 / VireoFood-172** | Asian dishes with ingredient labels | Broader Asian coverage; curry-type dishes transfer reasonably to deshi food |
| **FoodSeg103** | Segmentation masks | Pretraining the segmentation head |
| **DeshiFoodBD** | 5,425 images, 19 Bangladeshi dishes, Bangla + English labels | Extra Bangladeshi coverage; note much of it is web-scraped (professional food photos), so it differs from real user photos |
| **BanglaVeg** | 4,319 images, 12 Bangladeshi vegetables | Ingredient-level recognition for raw vegetables |

**Nutrition reference tables (not ML datasets — these are your food DB source):**

- ⭐ **Food Composition Table for Bangladesh (2013)** — Shaheen et al., Institute of Nutrition and Food Science, University of Dhaka. **This is your authoritative per-100g nutrient source for local foods.** FoodBD itself used it.
- **"Deshio Khadodrobber Pustiman"** (INFS, University of Dhaka) — food values of Bangladeshi local foods, in Bangla.
- **Indian Food Composition Tables (IFCT 2017), NIN Hyderabad** — good overlap for shared subcontinental dishes.
- **USDA FoodData Central** — free API, huge, best for packaged/imported foods.
- **International Tables of Glycemic Index and Glycemic Load** (Atkinson, Foster-Powell & Brand-Miller, *Diabetes Care* 2008) — your GI source. Watch out: compute GL from **available carbohydrate grams**, not total food weight.
- **Open Food Facts** — free, open barcode database for packaged products.

**Recommended vision recipe:**

```
1. Backbone pretrained on Food-101 + FoodSeg103
2. Fine-tune segmentation + classification on FoodBD (67 deshi classes)
3. Map class → Food Composition Table for Bangladesh → per-100g nutrients
4. Portion: LiDAR/ARCore depth where available
            → else reference-object scaling
            → else discrete portion buckets + user confirmation
5. Compute GL properly: GL = (GI × available carbs in g) / 100
6. Ship a VLM fallback for unrecognised plates in V1;
   distil into on-device model once you have user corrections
```

---

### 17.4 Going international — datasets per region ⭐ *new in v2*

#### 17.4a Risk-model datasets by market

| Market | Dataset | Notes |
|---|---|---|
| 🌍 **Global backbone** | **CDC BRFSS** (253k / 433k versions) | Your pretraining corpus regardless of market |
| 🇺🇸 USA | **NHANES** | Lab-confirmed HbA1c and fasting glucose → objective labels, not self-report. Best available for the Tier-2 lab model. Free. |
| 🇺🇸 USA | **All of Us Research Program** (NIH) | ~1M participants, longitudinal EHR + surveys + biometrics, deliberately diverse. Registration and data-use agreement required. Excellent for fairness testing across ethnicities. |
| 🇬🇧 UK | **UK Biobank** | 500k participants with long follow-up. The gold standard for *longitudinal* risk. Application + fee required, and commercial access has its own terms. |
| 🇮🇳 India | **ICMR-INDIAB** study results; **Indian Diabetes Risk Score (IDRS / MDRF)** | IDRS is a validated, transparent 4-item score (age, waist, family history, activity) — perfect as your Layer-1 clinical score for South Asia |
| 🇧🇩 Bangladesh | **DiaBD**, **BDHS 2022**, Pabna hospital dataset | As in §17.1 |
| 🇨🇳 China | **CHARLS** (China Health and Retirement Longitudinal Study) | Public, longitudinal, includes blood biomarkers |
| 🇰🇷 Korea | **KNHANES** | Public national survey with labs |
| 🇲🇽 Mexico | **ENSANUT** | National health and nutrition survey |
| 🌍 Prevalence priors | **IDF Diabetes Atlas** | Country-level prevalence — use as your calibration prior for any market where you lack a local validation set |
| 🌍 Clinical scores | **FINDRISC** (Finland/Europe), **ADA Risk Test** (US), **IDRS** (India), **Cambridge Risk Score** (UK) | Your transparent Layer-1 per region. These are published, validated, and explainable — exactly what regulators and doctors want to see. |

#### 17.4b Longitudinal datasets for Model D (§7.5 Phase 3)

To bootstrap a trajectory model before you have your own cohort:

| Dataset | Why it's useful | Access |
|---|---|---|
| **Diabetes Prevention Program (DPP) & DPP Outcomes Study** | ⭐ The single most relevant dataset in existence for your product: a randomised trial of *lifestyle intervention* (diet + activity) vs metformin vs placebo in people with prediabetes, with years of follow-up. It literally measures what your app claims to do. | NIDDK Central Repository, data request |
| **Look AHEAD** | Long-term intensive lifestyle intervention in people with T2D | NIDDK Central Repository |
| **UK Biobank** | Long follow-up, incident diabetes outcomes | Application + fee |
| **All of Us** | Longitudinal EHR + wearable data for a subset | DUA required |
| **ARIC / Framingham Offspring** | Classic long-run cardiometabolic cohorts | NHLBI BioLIC |
| **Your own cohort** | The only data that reflects *your* users, *your* features, and *your* markets | Build the pipeline from day one — instrument it now, use it in 18 months |

> The most valuable dataset you will ever have is the one your own users generate. Design the consent, the schema, and the labelling pipeline in Phase 0, even though you can't train on it until Phase 5.

#### 17.4c Food & nutrition data by region

Each market needs a **food pack**. Reuse across culturally adjacent markets is high — plan packs, not countries.

| Region | Food composition source | Image dataset |
|---|---|---|
| 🇧🇩 Bangladesh | **Food Composition Table for Bangladesh** (INFS, Dhaka University) | **FoodBD** ⭐, DeshiFoodBD, BanglaVeg |
| 🇮🇳 India / 🇵🇰 / 🇳🇵 / 🇱🇰 | **IFCT 2017** (NIN Hyderabad) | Indian Food Images (Kaggle), Food-101 subset |
| 🇺🇸 USA | **USDA FoodData Central** (free API) | Food-101, Nutrition5k |
| 🇬🇧 UK | **McCance & Widdowson's Composition of Foods** | Food-101 |
| 🇫🇷 France | **CIQUAL** (ANSES) | |
| 🇩🇰 Denmark / Nordics | **FRIDA** | |
| 🇯🇵 Japan | Standard Tables of Food Composition in Japan | **UEC-Food 256** |
| 🇨🇳 China | China Food Composition Tables | **ChineseFoodNet**, **VireoFood-172** |
| 🇸🇦🇦🇪 MENA | FAO/INFOODS regional tables | Limited — expect to build your own |
| 🌍 Packaged goods | **Open Food Facts** (free, open, global barcode DB) ⭐ | Product photos included |
| 🌍 Fallback | **FAO/INFOODS** global and regional food composition tables | |
| 🌍 Glycemic index | **International Tables of GI and GL** (Atkinson et al.) | |

**Food-pack build cost is your real internationalisation bottleneck** — not translation. Budget roughly **4–8 weeks per new cuisine** for: composition table licensing, top-200 dish curation, image collection/annotation, portion-unit definition, and native-speaker review. Plan for it explicitly in each wave.

**Cheapest path to a new market:** ship with (a) Open Food Facts for packaged goods, (b) the regional composition table for staples, and (c) a **VLM fallback** for unrecognised dishes. Then let user corrections build your image dataset organically. Do not try to hand-annotate 5,000 images before launching a market.

### 17.3 Data licensing checklist before you ship

- [ ] FoodBD — CC-BY 4.0: **attribution required in-app** (Settings → Acknowledgements). Cite Ahmed et al., *BMC Research Notes* 2026.
- [ ] DiaBD — check the Mendeley licence; cite Prama et al., *Data in Brief* 2025.
- [ ] Nutrition5k — check Google's licence terms for commercial use.
- [ ] Food-101 — research-use terms; verify before commercial deployment.
- [ ] BRFSS — US public domain, free for commercial use.
- [ ] Food Composition Table for Bangladesh — obtain permission from INFS, University of Dhaka for commercial redistribution of the values.
- [ ] Kaggle-sourced datasets — verify the *original* licence, not just the Kaggle page.

> ⚠️ Several of these are CC-BY (attribution) or research-only. For a **paid** app, confirm every licence in writing before launch. This is a real legal exposure, not a formality.

---

## 18. Appendix B — Definition of Done (V1)

- [ ] All §3 disclaimers implemented and localised
- [ ] Red-flag interceptor covers every free-text and vitals input path
- [ ] "How our AI works" page live and linked from the store listing
- [ ] Risk model calibration curve published; AUC reported on a Bangladeshi hold-out set
- [ ] All calorie outputs displayed as ranges with confidence labels
- [ ] Nutrition safety rails (§5.4) unit-tested with adversarial inputs
- [ ] Full offline mode: log, count steps, compute risk with zero network
- [ ] Bangla and English complete — no untranslated strings, no clipped Bangla text
- [ ] Export + delete account flows working end-to-end
- [ ] No health data reaches any third-party analytics SDK (verified by proxy inspection)
- [ ] Accessibility: AA contrast, dynamic type, screen-reader labels
- [ ] Reviewed by a registered Bangladeshi physician; sign-off documented
- [ ] Penetration test completed
- [ ] Privacy policy + Data Safety form (Play) + Privacy Nutrition Label (App Store) submitted

### Additional gates for v2 features

**Daily monitoring (F14) — before enabling**
- [ ] Red-flag interceptor runs on every check-in submission
- [ ] No trend shown before 14 days / 3 weigh-ins (cold-start rule)
- [ ] Rising-risk states use neutral styling and always pair with one concrete action
- [ ] Weight-anxiety guard tested
- [ ] Trajectory computes on-device and offline

**Multi-profile (F15) — before enabling**
- [ ] Adversarial cross-profile access test passes (valid token for profile A cannot read profile B)
- [ ] Row-level security enforced at the database layer, not just the API
- [ ] Invite-and-claim flow: no adult profile exists without that adult's consent
- [ ] Revocation propagates within one sync cycle, verified end-to-end
- [ ] Access audit log visible to the patient
- [ ] Active profile is unambiguous in the UI and named in every confirmation toast
- [ ] Under-18 profile creation blocked
- [ ] Account deletion unlinks rather than deletes self-managed member profiles

**Clinician mode (F16) — before enabling, per region**
- [ ] Regulatory intended-purpose document written, reviewed by counsel, under version control
- [ ] Region feature flag confirmed off in the EU
- [ ] Zero data access for unverified clinicians — automated test
- [ ] Manual verification process staffed with a documented SLA
- [ ] DPA / BAA templates executed with every clinic customer
- [ ] Every clinician read writes a patient-visible audit row
- [ ] Clinician-set targets attributed by name in the patient app
- [ ] Safety-rail override requires a reason, logs an audit entry, notifies the patient
- [ ] **Screen-by-screen review: no clinician-facing screen contains a recommendation directed at the clinician**
- [ ] Methodology link reachable in one tap from every clinician screen showing a model output

**Per new market — before launch**
- [ ] Region pack complete: food DB, GI table, cutoffs, units, meal slots, safety thresholds
- [ ] Model validation status honestly declared (`Validated` / `Provisional` / `Not validated`)
- [ ] Per-region, per-sex, per-age-band model metrics reviewed
- [ ] All safety strings and disclaimers reviewed by a native-speaking clinician
- [ ] Data residency zone correct
- [ ] Local regulatory assessment on file
- [ ] RTL / text-expansion regression pass (if applicable)
- [ ] Local emergency number configured in the red-flag safety card

---

*End of PRD v2.0*
