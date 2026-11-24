"""Shared test setup.

No test may reach the real OpenRouter API: that would make the suite slow,
flaky, billed, and would send test data to a third party. The key is blanked
for every test, and the tests that exercise the model path patch
`app.services.llm.chat` with a fake.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import get_settings  # noqa: E402


@pytest.fixture(autouse=True)
def _no_real_language_model(monkeypatch):
    monkeypatch.setattr(get_settings(), "openrouter_api_key", "")
