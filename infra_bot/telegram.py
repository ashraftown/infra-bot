from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from typing import Any
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


LOGGER = logging.getLogger(__name__)


class TelegramError(RuntimeError):
    pass


@dataclass
class TelegramUpdate:
    update_id: int
    chat_id: int
    text: str
    username: str | None


class TelegramClient:
    def __init__(self, bot_token: str, timeout_seconds: int = 30):
        self.bot_token = bot_token
        self.timeout_seconds = timeout_seconds
        self.base_url = f"https://api.telegram.org/bot{bot_token}"

    def _request(self, method: str, payload: dict[str, Any]) -> dict[str, Any]:
        data = urlencode(payload).encode("utf-8")
        request = Request(f"{self.base_url}/{method}", data=data, method="POST")
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read().decode("utf-8")
        except URLError as exc:
            raise TelegramError(str(exc)) from exc

        parsed = json.loads(body)
        if not parsed.get("ok"):
            raise TelegramError(str(parsed))
        return parsed

    def send_message(self, chat_id: int, text: str) -> None:
        self._request("sendMessage", {"chat_id": chat_id, "text": text})

    def get_updates(self, offset: int | None = None, timeout: int = 30) -> list[TelegramUpdate]:
        payload: dict[str, Any] = {"timeout": timeout}
        if offset is not None:
            payload["offset"] = offset
        response = self._request("getUpdates", payload)
        updates: list[TelegramUpdate] = []
        for item in response.get("result", []):
            message = item.get("message") or {}
            chat = message.get("chat") or {}
            text = message.get("text")
            if not text:
                continue
            updates.append(
                TelegramUpdate(
                    update_id=int(item["update_id"]),
                    chat_id=int(chat["id"]),
                    text=str(text),
                    username=(message.get("from") or {}).get("username"),
                )
            )
        return updates

    def send_many(self, chat_ids: list[int], text: str) -> list[str]:
        errors: list[str] = []
        for chat_id in chat_ids:
            try:
                self.send_message(chat_id, text)
            except TelegramError as exc:
                LOGGER.warning("telegram send failed for chat %s: %s", chat_id, exc)
                errors.append(f"{chat_id}: {exc}")
        return errors
