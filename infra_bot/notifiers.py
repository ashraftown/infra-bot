from __future__ import annotations

from typing import Any, Protocol


class Notifier(Protocol):
    name: str

    def send(self, text: str) -> list[str]:
        ...


class TelegramNotifier:
    name = "telegram"

    def __init__(self, client: Any, chat_ids: list[int]):
        self.client = client
        self.chat_ids = chat_ids

    def send(self, text: str) -> list[str]:
        return self.client.send_many(self.chat_ids, text)


class SlackNotifier:
    name = "slack"

    def __init__(self, client: Any, channel_ids: list[str]):
        self.client = client
        self.channel_ids = channel_ids

    def send(self, text: str) -> list[str]:
        return self.client.send_many(self.channel_ids, text)
