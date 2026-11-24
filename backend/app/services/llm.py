"""OpenRouter client — the one place the backend talks to a language model.

Used by two features, and only by these two:

  * the coach (`services/coach.py`), text in and text out
  * the camera calorie estimate (`services/food_vision.py`), an image in and
    JSON out

Both callers treat :class:`LLMUnavailable` as an ordinary outcome rather than
an error. With no API key configured, or with OpenRouter down, the coach
answers with fixed wording and the camera falls back to manual entry. A health
app that stops working when a third-party API has a bad minute is not one
people can rely on.

Safety never depends on this module. The red-flag interceptor runs before any
call is made here, so a model is never what decides whether "chest pain" is an
emergency.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

import httpx

from app.config import get_settings

log = logging.getLogger(__name__)


class LLMUnavailable(Exception):
    """No model is configured, or the call failed. Callers fall back."""


def is_configured() -> bool:
    return bool(get_settings().openrouter_api_key.strip())


def chat(
    messages: list[dict[str, Any]],
    *,
    temperature: float = 0.4,
    max_tokens: int = 900,
    json_mode: bool = False,
) -> str:
    """One chat completion. Returns the assistant's text.

    `messages` is the OpenAI-style list OpenRouter accepts. Image parts use
    `{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}`.
    """
    settings = get_settings()
    key = settings.openrouter_api_key.strip()
    if not key:
        raise LLMUnavailable("OPENROUTER_API_KEY is not set")

    payload: dict[str, Any] = {
        "model": settings.openrouter_model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        # Qwen 3.7 Flash can "think" before answering. Neither a chat reply
        # nor a plate photo needs it, and thinking tokens would eat into
        # max_tokens and add seconds the user spends staring at a spinner.
        "reasoning": {"enabled": False},
    }
    if json_mode:
        payload["response_format"] = {"type": "json_object"}

    try:
        res = httpx.post(
            f"{settings.openrouter_base_url.rstrip('/')}/chat/completions",
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
                # OpenRouter's optional attribution headers. Generic on purpose.
                "X-Title": "DiaVision",
            },
            json=payload,
            timeout=settings.llm_timeout_seconds,
        )
    except httpx.HTTPError as exc:
        log.warning("OpenRouter request failed: %s", exc)
        raise LLMUnavailable(str(exc)) from exc

    if res.status_code != 200:
        # Never log the request body: it carries the user's health data.
        log.warning("OpenRouter returned %s: %s", res.status_code, res.text[:300])
        raise LLMUnavailable(f"http_{res.status_code}")

    try:
        data = res.json()
        content = data["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise LLMUnavailable("malformed response") from exc

    # Some providers return a list of content parts rather than a string.
    if isinstance(content, list):
        content = "".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    text = (content or "").strip()
    if not text:
        raise LLMUnavailable("empty response")
    return text


_FENCE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)


def parse_json(text: str) -> Any:
    """Parse a model's JSON reply, tolerating a Markdown fence around it."""
    cleaned = _FENCE.sub("", text.strip())
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        # Last resort: the outermost object in the text.
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start != -1 and end > start:
            try:
                return json.loads(cleaned[start:end + 1])
            except json.JSONDecodeError:
                pass
    raise LLMUnavailable("model did not return JSON")
