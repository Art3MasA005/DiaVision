"""Photo → proposed meal items, via the vision model on OpenRouter.

**The model proposes, the user disposes.** Nothing returned here is saved.
The client shows every item with its portion, the user edits or removes what
is wrong, and only `POST /meals` stores anything, with `entry_method='photo'`.

How an item's numbers are decided, in order of trust:

  1. The model names the food and, where it can, picks the matching row from
     the region's food table (the list is in the prompt). A matched item uses
     the table's composition and the table's glycemic index.
  2. An item with no table row carries the model's own per-100 g estimate,
     flagged `source='ai_estimate'`. Its glycemic load is left unknown: a
     guessed GI on a blood-sugar app is worse than none.

Portions are the model's estimate from the photo and are the least certain
number here, which is why the meal is shown as a ±24% range (the `photo`
width in `nutrition.UNCERTAINTY`) and why every portion has a stepper.

The photo is sent to the model and is not stored by this server.
"""

from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass, field
from typing import Any

from app.services import llm

MAX_ITEMS = 12

# Units the client knows how to show, in the region's own words.
KNOWN_UNITS = ("plate", "bowl", "cup", "piece", "spoon", "slice", "ladle", "serving", "g")

PROMPT = """You are a food-recognition assistant for a calorie tracker used in Bangladesh.

Look at the photo and list every distinct food or drink you can see. Bangladeshi home and restaurant food is the most likely: rice (ভাত), dal, fish curry (মাছের ঝোল), chicken curry, bhaji, bhorta, roti/paratha, khichuri, biryani, egg, salad, fruit, tea, sweets.

FOOD TABLE (match an item to one of these names when it is clearly the same food; otherwise use null):
{table}

Return ONLY a JSON object, no prose, in exactly this shape:
{{
  "is_food": true,
  "scale_reference": false,
  "items": [
    {{
      "name_en": "Plain boiled rice",
      "name_bn": "সাদা ভাত",
      "match": "Rice, boiled" ,
      "quantity": 1.5,
      "unit": "cup",
      "grams": 240,
      "confidence": 0.8,
      "box": [0.10, 0.20, 0.45, 0.40],
      "per_100g": {{"kcal": 130, "carbs_g": 28, "protein_g": 2.7, "fat_g": 0.3, "fibre_g": 0.4}}
    }}
  ]
}}

Rules:
- "match": the exact name from the FOOD TABLE, or null.
- "unit": one of {units}. Prefer the local unit a Bangladeshi person would use (cup or plate for rice, bowl for dal, piece for fish/egg/roti).
- "grams": your best estimate of the total weight of that item on the plate. Use the plate, cutlery or a hand for scale.
- "confidence": 0 to 1, how sure you are of the food's identity.
- "box": where the item is in the photo as [x, y, width, height], each 0 to 1 from the top-left corner.
- "per_100g": typical composition of that dish as cooked in Bangladesh, including cooking oil.
- "scale_reference": true if a spoon, fork, hand or thumb is visible for size.
- If the photo shows no food, return {{"is_food": false, "scale_reference": false, "items": []}}.
- At most {max_items} items. Do not list plates, cutlery or the table.
"""


class InvalidImage(ValueError):
    """The upload is not a usable image."""


@dataclass
class Proposal:
    name: str
    name_local: str | None
    food_id: Any | None
    quantity: float
    unit: str
    grams: float
    confidence: float
    box: list[float] | None
    kcal_per_100g: float
    carbs_g_per_100g: float
    protein_g_per_100g: float
    fat_g_per_100g: float
    fibre_g_per_100g: float
    glycemic_index: float | None
    source: str  # 'table' | 'ai_estimate'
    portion_grams: dict[str, float] = field(default_factory=dict)


@dataclass
class VisionResult:
    is_food: bool
    scale_reference: bool
    items: list[Proposal]


def decode_image(image_base64: str) -> bytes:
    """Strip a data-URL prefix if present and check it is a real image."""
    raw = image_base64.strip()
    if raw.startswith("data:"):
        raw = raw.split(",", 1)[-1]
    try:
        data = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise InvalidImage("not base64") from exc
    if len(data) < 100:
        raise InvalidImage("too small")
    if not (data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n"
            or data[8:12] == b"WEBP" or data[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1")):
        raise InvalidImage("unsupported format")
    return data


def _mime_for(data: bytes) -> str:
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[8:12] == b"WEBP":
        return "image/webp"
    return "image/heic"


def _num(value: Any, lo: float, hi: float, default: float | None = None) -> float | None:
    try:
        v = float(value)
    except (TypeError, ValueError):
        return default
    if v != v:  # NaN
        return default
    return max(lo, min(hi, v))


def _box(value: Any) -> list[float] | None:
    if not isinstance(value, (list, tuple)) or len(value) != 4:
        return None
    nums = [_num(v, 0.0, 1000.0) for v in value]
    if any(n is None for n in nums):
        return None
    # Qwen's grounding habitually answers on a 0–1000 grid; accept both.
    if max(nums) > 1.0:  # type: ignore[type-var]
        nums = [n / 1000.0 for n in nums]  # type: ignore[operator]
    x, y, w, h = (min(1.0, n) for n in nums)  # type: ignore[type-var]
    if w <= 0 or h <= 0:
        return None
    return [round(x, 4), round(y, 4), round(min(w, 1 - x), 4), round(min(h, 1 - y), 4)]


def recognize(image: bytes, foods: list[dict]) -> VisionResult:
    """Ask the model what is on the plate. Raises `llm.LLMUnavailable`."""
    table_lines = []
    by_name: dict[str, dict] = {}
    for f in foods:
        local = f" / {f['name_local']}" if f.get("name_local") else ""
        units = ", ".join(sorted((f.get("portion_grams") or {}).keys()))
        table_lines.append(f"- {f['name_en']}{local}" + (f" (units: {units})" if units else ""))
        by_name[f["name_en"].strip().lower()] = f
        if f.get("name_local"):
            by_name.setdefault(f["name_local"].strip().lower(), f)

    prompt = PROMPT.format(
        table="\n".join(table_lines) or "(empty)",
        units=", ".join(KNOWN_UNITS),
        max_items=MAX_ITEMS,
    )
    data_url = f"data:{_mime_for(image)};base64,{base64.b64encode(image).decode()}"
    text = llm.chat(
        [{"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": data_url}},
        ]}],
        temperature=0.1,
        max_tokens=2000,
        json_mode=True,
    )
    parsed = llm.parse_json(text)
    if not isinstance(parsed, dict):
        raise llm.LLMUnavailable("model returned a non-object")

    proposals: list[Proposal] = []
    for raw in (parsed.get("items") or [])[:MAX_ITEMS]:
        if not isinstance(raw, dict):
            continue
        name_en = str(raw.get("name_en") or "").strip()[:160]
        if not name_en:
            continue
        name_bn = str(raw.get("name_bn") or "").strip()[:160] or None

        match_key = str(raw.get("match") or "").strip().lower()
        food = by_name.get(match_key) or by_name.get(name_en.lower()) \
            or (by_name.get(name_bn.lower()) if name_bn else None)

        unit = str(raw.get("unit") or "serving").strip().lower()
        if unit not in KNOWN_UNITS:
            unit = "serving"
        quantity = _num(raw.get("quantity"), 0.25, 20, 1.0) or 1.0
        grams = _num(raw.get("grams"), 1, 2000)
        confidence = _num(raw.get("confidence"), 0, 1, 0.5) or 0.0

        if food is not None:
            table_units = {k: float(v) for k, v in (food.get("portion_grams") or {}).items()}
            if grams is None:
                grams = quantity * table_units.get(unit, 120.0)
            proposals.append(Proposal(
                name=food["name_en"], name_local=food.get("name_local") or name_bn,
                food_id=food["id"], quantity=quantity, unit=unit, grams=round(grams, 1),
                confidence=confidence, box=_box(raw.get("box")),
                kcal_per_100g=float(food.get("kcal_per_100g") or 0),
                carbs_g_per_100g=float(food.get("carbs_g_per_100g") or 0),
                protein_g_per_100g=float(food.get("protein_g_per_100g") or 0),
                fat_g_per_100g=float(food.get("fat_g_per_100g") or 0),
                fibre_g_per_100g=float(food.get("fibre_g_per_100g") or 0),
                glycemic_index=food.get("glycemic_index"),
                source="table",
                portion_grams={**table_units, unit: round(grams / quantity, 1)},
            ))
            continue

        per = raw.get("per_100g") if isinstance(raw.get("per_100g"), dict) else {}
        kcal = _num(per.get("kcal"), 0, 900)
        if kcal is None:
            # No composition at all: still propose it so the user can see it
            # was spotted, but at zero until they pick a table food instead.
            kcal = 0.0
        if grams is None:
            grams = quantity * 120.0
        proposals.append(Proposal(
            name=name_en, name_local=name_bn, food_id=None,
            quantity=quantity, unit=unit, grams=round(grams, 1),
            confidence=confidence, box=_box(raw.get("box")),
            kcal_per_100g=kcal,
            carbs_g_per_100g=_num(per.get("carbs_g"), 0, 100, 0.0) or 0.0,
            protein_g_per_100g=_num(per.get("protein_g"), 0, 100, 0.0) or 0.0,
            fat_g_per_100g=_num(per.get("fat_g"), 0, 100, 0.0) or 0.0,
            fibre_g_per_100g=_num(per.get("fibre_g"), 0, 100, 0.0) or 0.0,
            glycemic_index=None,
            source="ai_estimate",
            portion_grams={unit: round(grams / quantity, 1)},
        ))

    return VisionResult(
        is_food=bool(parsed.get("is_food", bool(proposals))),
        scale_reference=bool(parsed.get("scale_reference", False)),
        items=proposals,
    )
