import socket
from urllib.error import URLError

import pytest

from infra_bot.telegram import TelegramClient, TelegramError, TelegramUpdate


class FakeTelegramClient(TelegramClient):
    def __init__(self):
        pass

    def _request(self, method, payload):
        if method == "getUpdates":
            return {
                "ok": True,
                "result": [
                    {
                        "update_id": 10,
                        "message": {
                            "text": "/status",
                            "chat": {"id": 123},
                            "from": {"username": "ash"},
                        },
                    }
                ],
            }
        return {"ok": True, "result": True}


def test_get_updates_parses_message() -> None:
    client = FakeTelegramClient()
    updates = client.get_updates()
    assert updates == [TelegramUpdate(update_id=10, chat_id=123, text="/status", username="ash")]


@pytest.mark.parametrize(
    ("raised", "expected"),
    [
        (TimeoutError("timed out"), "timed out"),
        (socket.timeout("socket timed out"), "socket timed out"),
        (URLError("temporary failure"), "temporary failure"),
    ],
)
def test_request_wraps_transport_timeouts(monkeypatch, raised, expected) -> None:
    client = TelegramClient("token")

    def fake_urlopen(request, timeout):
        raise raised

    monkeypatch.setattr("infra_bot.telegram.urlopen", fake_urlopen)

    with pytest.raises(TelegramError, match=expected):
        client.get_updates()
