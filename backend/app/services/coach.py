"""The coach — PRD §F10.

**There is no language model behind this, and the responses say so.**

The PRD calls this an AI coach and `packs/bd.json` ships `ai_coach: false` for
this slice. Rather than wire a model that is not procured, not evaluated and
not safety-tested, this answers from the user's OWN logged data with fixed
wording, and tells the user plainly that it is doing that. When a model is
added later it slots in behind [respond] — the interceptor, the deflection
rules and the cap all stay exactly where they are, which is the point of
building them first.

Three guards, in this order, and the order matters:

  1. **Red flags run before anything else.** `safety.check_text` sees the
     message before any responder does. A model must never be the thing that
     decides whether "chest pain" is an emergency.
  2. **Medication and dose questions are deflected**, always, to a doctor.
  3. **The coach never generates a number.** It quotes figures the user
     already logged, or it says it does not know. Inventing a calorie target
     or a glucose reading in a chat bubble is how a health app hurts someone.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from app.safety import SafetyCard, check_text

# Anything touching drugs, dose or insulin goes to a clinician, full stop.
MEDICATION_PATTERNS = [
    r"\bmetformin\b", r"\binsulin\b", r"\bdose\b", r"\bdosage\b",
    r"\bmedication\b", r"\bmedicine\b", r"\btablet[s]?\b", r"\bpill[s]?\b",
    r"\bprescription\b", r"\bglicla?zide\b", r"\bempagliflozin\b",
    r"\bshould i (stop|start|take|skip)\b",
    r"ওষুধ", r"ইনসুলিন",
]

# Questions that are really "do I have diabetes?". The app screens; it does
# not answer that, and saying so is better than hedging.
DIAGNOSIS_PATTERNS = [
    r"\bdo i have\b", r"\bam i diabetic\b", r"\bhave i got\b",
    r"\bis it diabetes\b", r"\bআমার কি ডায়াবেটিস\b",
]


@dataclass
class CoachReply:
    body: str
    intercepted: bool = False
    safety_card: SafetyCard | None = None
    # What the answer was built from, so the client can show its evidence.
    cited: list[str] = None  # type: ignore[assignment]

    def __post_init__(self) -> None:
        if self.cited is None:
            self.cited = []


def _matches(text: str, patterns: list[str]) -> bool:
    lowered = text.lower()
    return any(re.search(p, lowered) for p in patterns)


DISCLOSURE = (
    "I answer from what you have logged in this app — I am not a doctor and "
    "not a medical service."
)


def respond(message: str, context: dict[str, Any]) -> CoachReply:
    """Answer one turn.

    `context` carries only this profile's own recent figures, already fetched
    by the caller: `mean_kcal`, `mean_steps`, `latest_glucose`,
    `latest_risk_range`, `days_logged`.
    """
    text = (message or "").strip()
    if not text:
        return CoachReply(body="Ask me about your logs — food, movement, or your readings.")

    # 1. Red flags, before anything else looks at the message.
    card = check_text(text)
    if card is not None:
        return CoachReply(
            body=card.body,
            intercepted=True,
            safety_card=card,
        )

    # 2. Medication is a clinician's territory.
    if _matches(text, MEDICATION_PATTERNS):
        return CoachReply(
            body=("I can't help with medication or dosing — that has to come from "
                  "the doctor who prescribed it. If something about your medicine "
                  "is worrying you, please contact them rather than waiting."),
            intercepted=True,
        )

    # 3. The screening question this app deliberately does not answer.
    if _matches(text, DIAGNOSIS_PATTERNS):
        return CoachReply(
            body=("I can't tell you that, and neither can this app — only a blood "
                  "test ordered by a doctor can. What the app gives you is an "
                  "estimate of how likely it is that a test would find something, "
                  "so it is worth taking that estimate to a doctor."),
            intercepted=True,
        )

    lowered = text.lower()
    cited: list[str] = []

    # Everything below quotes the user's own logged figures, or admits it has
    # nothing. It never computes a new recommendation.
    if any(w in lowered for w in ("calorie", "kcal", "eat", "food", "খাবার", "ক্যালরি")):
        mean = context.get("mean_kcal")
        if mean:
            cited.append("your logged meals")
            body = (f"Across your logged days you have averaged about "
                    f"{int(mean)} kcal. The most useful change is usually the "
                    f"size of the largest carbohydrate portion rather than "
                    f"cutting a whole meal.")
        else:
            body = ("You have not logged enough meals yet for me to say anything "
                    "useful about your intake. A few days is usually enough.")
        return CoachReply(body=f"{body}\n\n{DISCLOSURE}", cited=cited)

    if any(w in lowered for w in ("step", "walk", "exercise", "active", "হাঁটা", "ব্যায়াম")):
        steps = context.get("mean_steps")
        if steps:
            cited.append("your activity log")
            body = (f"You have been averaging about {int(steps)} steps a day. "
                    f"Movement is one of only four things the clinical score "
                    f"reads, and it shows up in your estimate faster than "
                    f"weight does.")
        else:
            body = ("There is no activity logged yet. Even a walk after the "
                    "largest meal of the day is worth recording.")
        return CoachReply(body=f"{body}\n\n{DISCLOSURE}", cited=cited)

    if any(w in lowered for w in ("sugar", "glucose", "reading", "গ্লুকোজ", "সুগার")):
        latest = context.get("latest_glucose")
        if latest is not None:
            cited.append("your glucose log")
            body = (f"Your most recent logged reading was {latest} mmol/L. One "
                    f"reading on its own says very little — the spread across "
                    f"several is what a doctor will want to see.")
        else:
            body = ("You have not logged a glucose reading yet. If you have a "
                    "recent lab report, adding the HbA1c narrows your estimate "
                    "more than anything else you can do here.")
        return CoachReply(body=f"{body}\n\n{DISCLOSURE}", cited=cited)

    if any(w in lowered for w in ("risk", "score", "estimate", "ঝুঁকি")):
        band = context.get("latest_risk_range")
        if band:
            cited.append("your last assessment")
            body = (f"Your last estimate came out at {band}. It is a range on "
                    f"purpose — the underlying figure is not precise enough to "
                    f"quote as a single number.")
        else:
            body = ("You have not completed an assessment yet. It is eleven "
                    "questions and takes about two minutes.")
        return CoachReply(body=f"{body}\n\n{DISCLOSURE}", cited=cited)

    return CoachReply(
        body=("I can talk about what you have logged — your meals, your movement, "
              "your readings, or your last estimate. For anything clinical, "
              "please ask a doctor.\n\n" + DISCLOSURE)
    )
