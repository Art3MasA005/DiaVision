# The Flutter app

All **19 screens** of the design handoff, built against the frozen
`ml/contracts/feature_spec.json` and the live backend at `127.0.0.1:8000`.
The backend for the second half — meals, check-ins, activity, coach, insights,
reports and billing — was added alongside them (migration `0003`).

```powershell
# backend, in one terminal
$env:PYTHONPATH="E:\Bye Bye Diabetes\backend"
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload --app-dir backend

# app, in another
cd app
flutter run                       # or: flutter run -d chrome
flutter test                      # 39 tests, no backend needed
flutter test test/live_backend_test.dart   # drives the real API
```

The API base URL defaults to `127.0.0.1:8000` (`10.0.2.2` on an Android
emulator) and can be overridden:

```powershell
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:8000/api/v1
```

---

## What is here

| Handoff # | Screen | File |
|---|---|---|
| 01 | Splash | [splash_screen.dart](lib/ui/screens/splash_screen.dart) |
| 02 | Log in / Sign up | [auth_screen.dart](lib/ui/screens/auth_screen.dart) |
| 03 | Disclaimer — blocking | [disclaimer_screen.dart](lib/ui/screens/disclaimer_screen.dart) |
| 04 | Wizard — the eleven questions | [wizard_screen.dart](lib/ui/screens/wizard_screen.dart) |
| 04b | **Waist guide** — `ui_spec.md` §2 screen 07 | [waist_guide_screen.dart](lib/ui/screens/waist_guide_screen.dart) |
| 05 | Population guidelines | [population_screen.dart](lib/ui/screens/population_screen.dart) |
| 06 | Calculating | [calculating_screen.dart](lib/ui/screens/calculating_screen.dart) |
| 07 | Risk result + what-if | [risk_screen.dart](lib/ui/screens/risk_screen.dart) |
| 08 | Lab values (Tier 2) | [labs_screen.dart](lib/ui/screens/labs_screen.dart) |
| 09 | Home / My plan | [home_screen.dart](lib/ui/screens/home_screen.dart) |
| 10 | Calorie tracker | [tracker_screen.dart](lib/ui/screens/tracker_screen.dart) |
| 11 | Camera meal review | [scan_screen.dart](lib/ui/screens/scan_screen.dart) |
| 12 | Daily check-in | [checkin_screen.dart](lib/ui/screens/checkin_screen.dart) |
| 13 | Activity | [activity_screen.dart](lib/ui/screens/activity_screen.dart) |
| 14 | Glucose & vitals | [vitals_screen.dart](lib/ui/screens/vitals_screen.dart) |
| 15 | Coach | [coach_screen.dart](lib/ui/screens/coach_screen.dart) |
| 16 | Insights + doctor report | [insights_screen.dart](lib/ui/screens/insights_screen.dart) |
| 17 | Paywall | [paywall_screen.dart](lib/ui/screens/paywall_screen.dart) |
| 18 | Settings | [settings_screen.dart](lib/ui/screens/settings_screen.dart) |
| 19 | Safety, under-18, diagnosed, offline, error | [edge_states.dart](lib/ui/screens/edge_states.dart) |

The floating nav pill ([nav_pill.dart](lib/ui/widgets/nav_pill.dart)) carries
Home / Tracker / Scan / Activity / Coach. It is **hidden on splash, auth,
disclaimer and calculating** — those are gates, and a gate with an escape hatch
is not a gate. [Shell](lib/ui/widgets/shell.dart) enforces that by making the
pill opt-in, so the safe behaviour is what you get by not thinking about it.

## The backend added for the second half

Migration `0003` adds six profile-scoped tables — `meal_logs`,
`meal_log_items`, `daily_checkins`, `activity_logs`, `coach_messages`,
`reports` — plus `food_items` as reference data. All six are added to
`PROFILE_SCOPED_TABLES` and to the RLS loop in `rls.sql`, and the existing
test asserting those two lists match what PostgreSQL reports now covers them.

`meal_log_items` carries a denormalised `profile_id` for the same reason
`profile_memberships` carries `owner_account_id`: a policy that had to join
`meal_logs` would inherit that table's policy, and the dependency graph in
`rls.sql` has to stay a DAG.

New endpoints:

```
GET    /vitals                    read side — the write side already existed
GET    /foods                     the composition table, with its provenance
POST   /meals   GET /meals   DELETE /meals/{id}
POST   /food/recognize            honest: no model, returns nothing
GET    /plan/today                targets + totals + meals, one round trip
POST   /checkins  GET /checkins/today  GET /checkins
POST   /activity  GET /activity   upserted per day, never appended
POST   /coach/message  GET /coach/history
GET    /insights/weekly
POST   /reports/generate  GET /reports/{id}
GET    /billing/plans  POST /billing/subscribe
PATCH  /me/preferences  POST /me/export  DELETE /me
```

Three service modules do the thinking:
[`nutrition.py`](../backend/app/services/nutrition.py) (portions, glycemic
load, targets through the §5.4 rails),
[`insights.py`](../backend/app/services/insights.py) (patterns and the report),
[`coach.py`](../backend/app/services/coach.py) (the guards).

---

## The missing asset, now drawn

The handoff lists two things as unfinished. One is in scope:

> **Illustration for the waist-measurement guide** (spec §2 screen 07) is not
> drawn. The prototype covers it with a "Why do we ask?" text explainer
> instead; a wordless diagram is still required per spec.

It is now [`ui/illustrations/waist_diagram.dart`](lib/ui/illustrations/waist_diagram.dart)
— four wordless panels drawn as vectors:

1. **Stand straight.** Whole figure, feet together, arms clear of the torso, a
   dashed plumb line down the centre.
2. **Find the point.** The costal margin and the top of the hip bone in sage;
   a bracket showing the measuring point sitting exactly halfway between them.
3. **Wrap the tape, level.** The near half of the loop solid, the far half
   dashed, over a dotted floor-parallel rule — the mistake this panel exists to
   prevent is a tape that rides up at the back.
4. **Breathe out, then read.** Side view with a profile head, the belly curve
   the tape has to follow, and one curved exhale arrow.

Drawn rather than shipped as images, for reasons that are all shipping rules:

- **Rule 9 — no text baked into an image.** There is no text in the artwork.
  The step number beside each panel is live text through the numeral formatter,
  so it renders `২` in Bangla without a second asset.
- **Themes.** It reads the same tokens as everything else and flips with the
  theme, instead of shipping a light PNG onto a dark ground.
- **Accessibility.** Vector redraws crisply at the largest dynamic-type size,
  and the sequence carries one screen-reader description
  (`Strings.waistGuideA11y`) rather than being invisible.
- One file, versus eight raster assets across four densities and two themes.

The figure is schematic and un-gendered on purpose: no face, no hair, no
clothing, no body-type cue. Everyone sees this screen, it is about a tape
measure, and a drawing that read as a particular body would quietly tell some
users it was not about them.

Review the artwork as pictures:

```powershell
flutter test --update-goldens test/waist_diagram_golden_test.dart
flutter test --update-goldens test/screens_golden_test.dart
# then open test/goldens/
```

The **meal photography** the handoff also lists as missing belongs to screen
11 (camera meal review), which is Phase 2. Not built, not needed yet.

---

## Decisions taken while building

**The palette is the handoff's, not the spec's.** The handoff README flags the
divergence and asks for a decision: `docs/ui_spec.md` §6 proposes deep teal
`#0F766E`; `design-tokens.json` ships the Organic terracotta-and-sand system.
The tokens file wins — it is the later, machine-readable, high-fidelity source,
and "maintain the design" means the prototype. Nothing safety-critical turns on
it: safety `#9f1239` and caution `#a2560b` are identical in both. Recorded at
the top of [`core/tokens.dart`](lib/core/tokens.dart).

**Body text is 16sp everywhere, above several of the handoff's px values.**
The handoff specifies 12.5–15px for a lot of body copy; `ui_spec.md` rule 10
says never below 16sp because older adults are a core demographic. The ratios
of the type scale are kept and the floor is lifted. A design px value does not
outrank an accessibility rule.

**Bangla is drawn ~6% larger than Latin.** Noto Sans Bengali runs optically
smaller than Figtree at the same px, and the spec asks for both at the same
optical size. The nudge is in [`core/typography.dart`](lib/core/typography.dart).

**Caprasimo has no Bengali coverage**, so Bangla headings fall back to the
Bengali face at weight 700 rather than rendering tofu.

**The what-if simulator computes client-side, within bounds.** It is the only
thing on the risk screen not returned by the API. It moves the clinical-score
points the server already itemised for the modifiable factors and re-derives
the range from them; it never invents a model, it is labelled "simulated"
throughout, and it cannot go below what the fixed factors allow. A round trip
per slider drag would not be fast enough or kind to a low-bandwidth connection.

**Home is smaller than the handoff's.** The handoff's Home carries a day strip,
meals, a trajectory card and a check-in prompt — all Phase 2–4. A home screen
full of affordances that lead nowhere is worse than a small one.

---

## Things built honestly rather than faked

Three features in the design have no real implementation available, and each
one says so on screen rather than pretending:

**Photo food recognition (screen 11).** No model is wired, and `packs/bd.json`
ships `camera_food_logging: false`. `POST /food/recognize` returns an empty
proposal list with `model_available: false`, and the screen falls back to
search and manual portions. Inventing food items on a blood-sugar app is not a
cosmetic shortcut — it would put wrong carbohydrate figures in front of someone
managing their glucose. The endpoint exists now so the contract, the confidence
floor and the confirm-before-save flow are settled before a model arrives.

**The coach (screen 15).** There is no language model behind it. It answers
from the user's own logged figures using fixed wording, `model_backed: false`
comes back in every response, and the screen carries a banner saying so. What
*is* real is the guard chain, and that is the part worth building first: red
flags run before any responder sees the message; medication and dose questions
are deflected to a doctor; "do I have diabetes?" is refused outright. When a
model is added it slots in behind `coach.respond()` and the guards do not move.

**Payment (screen 17).** No rail is connected. `POST /billing/subscribe` moves
the account to `trial` so the entitlement path is exercisable end to end; it
takes no money and issues no receipt. bKash/Nagad and the store billing SDKs
are a separate job.

Also honest rather than convenient: the seeded food table is **not** the
Bangladesh food composition table, which `packs/bd.json` records as
`permission_pending`. The twenty seeded rows are widely-published
approximations marked `source: 'placeholder'`, the API returns that field, and
the UI says so. Foods with no widely-agreed glycemic index get
`glycemic_load: null` and the tracker shows the day's load as partial — a
guessed GL on a diabetes app is worse than an absent one.

## The "population screen won't advance" bug

Reported symptom: the population-guidelines screen's Continue and Skip did
nothing. Eleven answered questions, and a dead button.

Cause: `AppState.load()` restores the auth token from the keystore but
deliberately does **not** fetch the account or profile — cold start must not
depend on the network. Nothing else fetched them either, so on any launch that
restored a saved session the app had a valid token and `profile == null`.
`submitProfileAndAssess` read `app.profile?.id`, got null, showed a toast and
returned. Sixteen other call sites across ten screens had the same read, so
Home showed "My plan" instead of a name, the tracker had no target, and the
coach and vitals screens quietly did nothing.

It only appeared on a *restored* session, which is why it survived the first
round of testing — signing up or logging in calls `onAuthenticated`, which does
fetch the profile.

Three changes:

* `AppState.restoreSession()` re-fetches the account and profile for an
  already-valid token, and the splash screen calls it while resolving where to
  go. Failure is not fatal.
* `AppState.profileId` falls back to the id cached at sign-in, so a session
  restored without a network still knows whose record it is.
* `submitProfileAndAssess` now recovers the session itself before giving up.
  Eleven answered questions must not be lost to a missing id.

Two tests pin it: one that `profileId` survives an unfetched profile, and a
blunt one asserting no screen reads `profile?.id` directly — that expression
looks correct in review, which is exactly why it needs a test rather than
vigilance.

## The worst bug found so far: "recorded" was a lie

`POST /vitals` with a dangerous glucose reading returns 409 with a safety card
and `"recorded": true`. The app shows the card, which tells the user their
reading was saved.

It was not. `db_session` rolls back on any exception, and an `HTTPException`
raised from a route **is** an exception — so the 409 undid the very row it
claimed to have stored. Verified against the live server: the response said
recorded, `GET /vitals` returned zero rows.

Someone logs a dangerous reading, is told it is on record, takes their phone to
a doctor, and there is nothing there. The route's own comment said "the reading
is still recorded — refusing to store it would lose clinical history"; the
implementation did the opposite.

The same applied to `POST /labs`, `POST /checkins`, and the under-18 safety
event on `PUT /profiles/{id}/health` — and PRD §14 measures the false-negative
rate from `safety_events` rows that were being rolled back.

`raise_safety_card()` now commits before raising. Three tests pin it, and they
assert by **re-reading**, never by trusting the flag in the response.

## A safety bug the new tests found

`clamp_calorie_target` had a path that escaped its own floor. When BMI was
below 18.5 it returned `tdee` untouched, and for a small, elderly, sedentary
person maintenance computes to about **930 kcal** — under the 1200 female floor
the function exists to enforce, and under the 800 disordered-eating threshold.
The existing test passed `tdee=1900`, so the path was never exercised.

Fixed in [`safety.py`](../backend/app/safety.py): the low-BMI branch now
applies `max(tdee, floor)`. Someone below a healthy BMI should not be handed
the lowest target in the app.

## Gaps found, that are not in the app to fix

### 1. `ancestry_cutoff_group` is not wired through the backend

The ML layer supports it — `ml/pipelines/predict.py:226` reads
`record.get("ancestry_cutoff_group")` and `clinical_scores.py:445` applies
`ANCESTRY_SCORE` ahead of the region table. There are passing tests for it in
`ml/tests/test_predict.py`.

But the API layer has no such field:

- `backend/app/schemas.py` `HealthProfileIn` does not declare it
- `backend/app/db/models.py` `HealthProfile` has no column for it
- `backend/app/services/risk.py` `health_profile_to_record()` does not pass it

So **the diaspora fix is currently unreachable from the app.** A Bangladeshi in
London still gets scored on their region pack rather than their declared
cutoff group. Screen 05 collects the answer, the client sends it (extra fields
are ignored by Pydantic, so it is forward-compatible), and it is held in prefs
— but nothing downstream reads it yet.

Closing it needs three small changes plus a migration: a nullable
`ancestry_cutoff_group` column, the field on `HealthProfileIn`, and one line in
`health_profile_to_record`. That is a backend change, so it is flagged here
rather than done unasked.

### 2. The risk model does not actually run on-device

Both documents state the assessment runs on the phone and must work offline.
Today the model runs in-process **on the server** (`backend/app/services/risk.py`
imports `ml.pipelines.predict` directly), and there is no exported on-device
bundle.

Rather than ship a second, drifting implementation of a clinical score in Dart
— which in a health app is worse than being honest — the app:

- caches the last result verbatim and renders it offline,
- shows the quiet persistent offline banner, never a blocking dialog,
- keeps every write behind a clear error state that says nothing was lost.

A genuinely on-device assessment needs an exported model bundle and a Dart or
FFI scorer. Until then the offline story is "your last result still works",
which is true, rather than "your estimate runs here", which is not.

### 3. The Bangla safety strings have not had clinician review

`ui_spec.md` §7 requires every Bangla safety string to be reviewed by a
native-speaking clinician — not machine translation, not a developer's best
guess. The four safety strings are verbatim from the design prototype and are
marked in [`l10n/strings.dart`](lib/l10n/strings.dart) with a
`clinicianReviewPending` flag. While it is `true`, the disclaimer screen offers
the English wording alongside the Bangla. Flip the flag when the review has
happened.

### 4. Writes return before they commit

`POST /auth/signup` and `POST /consents` respond before their transaction
lands: the FastAPI `yield` dependency in `backend/app/api/routes.py` commits in
the generator's tail, *after* the response has been built. A read issued
immediately afterwards, on a different pooled connection, can still see the old
state.

**Fixed at the source.** FastAPI closes the dependency exit stack *after* the
response has been sent, so `db_session`'s commit landed a moment too late and a
client that saved then immediately re-read could miss its own write.

It first showed up as a flaky test (`may_answer_health_questions` false right
after accepting the disclaimer), which is easy to dismiss as a test problem.
It is not: the second half of the app saves and reloads constantly — save a
meal, pop back to the tracker, reload — and the meal would be missing until the
next refresh. Submitting a check-in, logging steps, and adding a lab value all
had the same shape.

`commit_before_responding()` in `routes.py` now commits at the end of every
write route, after the response object is built. The docstring carries the one
rule that matters: **call it only when nothing else in the request will
query**, because `set_actor` uses a transaction-local `SET LOCAL` and
committing clears the actor — any query after that point would be denied by RLS
and silently see nothing.

Ten consecutive full-suite runs are clean where four in ten used to fail.

### 5. Not wired, and says so

"Forgot password?" and "Find a doctor" have no backend behind them. Both toast
rather than pretending to work.

---

## Rules held by tests

`test/widget_test.dart` pins the ones that get the app rejected or hurt someone:

| Rule | Test |
|---|---|
| 1 · never a bare number | the formatter only produces ranges; `probability` has no display path |
| 2 · banned words | every user-facing string in EN **and** BN, word-boundary matched, minus explicit denials |
| 4 · safety red has one job | `safety` is unreachable from any ordinary colour role, in both themes |
| 5 · disclaimer not dismissible | the footer renders with no button, icon button or close affordance |
| 9 · no baked-in text | the diagram paints zero `Text` widgets |
| 10 · 16sp floor | every body style, in both scripts; Bangla ≥ Latin |
| 11 · under-18 blocked | the wizard gate, and it is not a setting |
| the frozen contract | wire field names, snake_case enum values, waist-null-not-zero, gestational-null-for-male, ranges |

Two found real bugs while being written: `whyDiabetesStatus` and
`diagnosedBody` both used a banned word, and `whyBpMeds` said "treatment".

`test/live_backend_test.dart` drives the real `Api` against the running server
across four tests: the onboarding flow (two-record consent split, 403 disclaimer
gate, Tier 1 → Tier 2 narrowing, 409 safety intercept with `recorded: true`),
the tracking half (portion maths, the calorie floor, activity upsert, the
coach's guards, evidence-backed insights, the report's basis line, the
free-forever list, export completeness), the coach's free cap as a paywall
branch, and the already-diagnosed branch. It skips itself when the backend is
not up.

`backend/tests/test_tracking_api.py` adds 30 tests on the same surface, weighted
towards what would hurt someone: the §5.4 floors, the check-in interceptor, the
coach's refusal to discuss medication, a safety message never being
rate-limited, and glycemic load using available carbohydrate rather than total
food weight.

Totals: **139 backend tests**, **53 Flutter tests** including 28 screen
goldens.

---

## Layout conventions

Held everywhere, because Arabic and Urdu are Wave 3 and retrofitting RTL is
brutal:

- `start`/`end`, `EdgeInsetsDirectional`, `PositionedDirectional` — never
  `left`/`right`
- flex `spacing:` for sibling gaps — never margin-per-child
- no fixed heights on anything containing text
- `Expanded`/`Flexible` on flex children holding text, so long Bangla wraps
  rather than overflowing
- tabular figures on every number that can change or stack
- focus is a 2px accent outline at 2px offset, never the platform default
