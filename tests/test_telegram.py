from infra_bot.telegram import TelegramClient, TelegramUpdate


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
