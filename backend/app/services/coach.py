"""The coach — PRD §F10.

An AI coach backed by a language model on OpenRouter (`qwen/qwen3.7-flash` by
default, see `config.py`). **The coach already has the user's data**: the
caller builds a snapshot of this profile's profile, risk estimate, labs,
vitals, meals, check-ins and activity (`services/user_snapshot.py`) and the
model answers from it. The user never has to type their own numbers in.

Three guards run BEFORE the model sees anything, in this order, and the order
matters:

  1. **Red flags run before anything else.** `safety.check_text` sees the
     message first. A model must never be the thing that decides whether
     "chest pain" is an emergency.
  2. **Medication and dose questions are deflected**, always, to a doctor.
  3. **"Do I have diabetes?" is refused outright** — only a blood test can
     answer it.

After the model answers, one more guard: a reply that contains a drug dose is
replaced with the medication deflection. The system prompt forbids it, but a
prompt is a request, not a guarantee.

With no API key, or with OpenRouter unreachable, the coach falls back to the
fixed-wording answers below. They quote the user's own figures and never
invent a number, and `model_backed=False` tells the client which one answered.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from app.safety import SafetyCard, check_text
from app.services import llm

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
    # True when the language model wrote the answer; False for a guard or the
    # fixed-wording fallback.
    model_backed: bool = False

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


MEDICATION_DEFLECTION = (
    "I can't help with medication or dosing — that has to come from "
    "the doctor who prescribed it. If something about your medicine "
    "is worrying you, please contact them rather than waiting."
)
MEDICATION_DEFLECTION_BN = (
    "ওষুধ বা ডোজ নিয়ে আমি পরামর্শ দিতে পারি না — সেটা যে ডাক্তার ওষুধ দিয়েছেন "
    "তাঁর কাছ থেকেই আসতে হবে। ওষুধ নিয়ে দুশ্চিন্তা থাকলে দেরি না করে তাঁর সাথে "
    "যোগাযোগ করুন।"
)

# A dose in a model's reply: "500 mg", "10 units", "২ ইউনিট". Replaced, never shown.
DOSE_PATTERN = re.compile(
    r"\b\d+(\.\d+)?\s?(mg|mcg|iu|units?)\b|[০-৯\d]+\s?(মিগ্রা|ইউনিট)",
    re.IGNORECASE,
)

SYSTEM_PROMPT = """You are the coach inside DiaVision, a diabetes-risk and lifestyle app for adults in Bangladesh.

You already have this user's data. It is below under USER DATA, read straight from the app's database. Use it directly. Never ask the user to tell you something that is already there (their weight, readings, meals, steps, risk estimate). If something is "not recorded" or "nothing logged", say so plainly and suggest logging it in the app; never guess it.

Rules you must always follow:
- You are not a doctor and this is not a medical service. Never diagnose. Never tell the user they do or do not have diabetes; only a blood test ordered by a doctor can say that.
- Never give medication, insulin or supplement advice or doses. Send those questions to their doctor.
- Never use the words cure, reverse or treat about diabetes.
- The risk estimate is a statistical screening estimate. Always present it as the range it is, never as a single precise number.
- Calories are estimates; talk about them as approximate.
- Do not invent figures. You may do simple arithmetic on the user's own numbers (totals, averages, differences) and say that you did.
- Prefer small, specific, achievable changes that fit Bangladeshi food and life: rice portion size, dal, vegetables, fish, roti, tea with less sugar, a walk after the biggest meal.
- If the user describes symptoms that could be serious (chest pain, fainting, confusion, very high or very low sugar readings, severe thirst with weight loss), tell them to get medical care now.
- When you discuss their risk or glucose readings, end with one short line suggesting they discuss it with a doctor.

Style:
- Reply in the language of the user's latest message (Bangla script for Bangla, also when they write Bangla in Latin letters). Use simple everyday words.
- Keep it short: at most about 120 words, unless they ask for a plan or a list.
- Plain text only. No Markdown: no **, no #, no tables. Short lines starting with "• " are fine for lists.
- Warm and practical, never scolding. Going over a target is not a failure.
"""


def _looks_bangla(text: str) -> bool:
    return any("ঀ" <= ch <= "৿" for ch in text)


def _model_reply(text: str, context: dict[str, Any]) -> CoachReply:
    """Ask the model. Raises `llm.LLMUnavailable` for the caller to fall back."""
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "system", "content": "USER DATA\n\n" + (context.get("text") or "none")},
    ]
    for turn in context.get("history") or []:
        if turn.get("content"):
            messages.append({"role": turn["role"], "content": turn["content"]})
    messages.append({"role": "user", "content": text})

    body = llm.chat(messages, temperature=0.4, max_tokens=900)
    body = body.replace("**", "").strip()

    if DOSE_PATTERN.search(body):
        return CoachReply(
            body=MEDICATION_DEFLECTION_BN if _looks_bangla(text) else MEDICATION_DEFLECTION,
            intercepted=True,
        )
    return CoachReply(body=body, cited=list(context.get("sections") or []),
                      model_backed=True)


def respond(message: str, context: dict[str, Any]) -> CoachReply:
    """Answer one turn.

    `context` is this profile's snapshot from `user_snapshot.build`: the
    data text and conversation history for the model, plus the summary
    figures (`mean_kcal`, `mean_steps`, `latest_glucose`,
    `latest_risk_range`, `days_logged`) the fixed-wording fallback uses.
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
            body=MEDICATION_DEFLECTION_BN if _looks_bangla(text) else MEDICATION_DEFLECTION,
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

    # 4. The model, with the user's data in hand.
    if llm.is_configured():
        try:
            return _model_reply(text, context)
        except llm.LLMUnavailable:
            pass  # fall through to the fixed wording

    return _fixed_reply(text, context)


def _fixed_reply(text: str, context: dict[str, Any]) -> CoachReply:
    """The no-model answer: quotes the user's own figures or admits it has none."""
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
