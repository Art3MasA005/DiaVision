"""Outgoing email. Used only for password reset codes.

Three states, and each one is honest about itself:

  * SMTP configured        the message is sent
  * no SMTP, development   the message is written to the server log, marked
                           DEV ONLY, so the reset flow can be tried end to end
  * no SMTP, production    `available()` is False and the reset routes answer
                           503 for every address alike, rather than telling a
                           user a code is on its way when none ever will be

Sending happens in a background task after the response, so the time a
request takes never reveals whether the address has an account.
"""

from __future__ import annotations

import logging
import smtplib
import ssl
from email.message import EmailMessage

from app.config import get_settings

log = logging.getLogger("diavision.mailer")


def configured() -> bool:
    s = get_settings()
    return bool(s.smtp_host and s.smtp_from)


def available() -> bool:
    return configured() or not get_settings().is_production


def send(to: str, subject: str, body: str) -> None:
    """Deliver one plain-text message. Never raises: a failed send is logged.

    The caller has already answered the request by now, and the answer was
    deliberately the same whether or not this address exists.
    """
    s = get_settings()
    if not configured():
        # Development only (`available()` is False in production). The body
        # holds the code, which is the point: there is nowhere else to read it.
        log.warning("DEV ONLY, no SMTP configured. Email to %s\n%s\n%s", to, subject, body)
        return

    msg = EmailMessage()
    msg["From"] = s.smtp_from
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        with smtplib.SMTP(s.smtp_host, s.smtp_port, timeout=20) as smtp:
            if s.smtp_starttls:
                smtp.starttls(context=ssl.create_default_context())
            if s.smtp_user:
                smtp.login(s.smtp_user, s.smtp_password)
            smtp.send_message(msg)
    except (OSError, smtplib.SMTPException) as exc:
        # Never log the body here: it carries a live code.
        log.error("Email to %s failed: %s", to, exc.__class__.__name__)
