import pytest

from infra_bot.config import AppConfig, MessagingConfig, PathConfig, RebootPolicy, SlackConfig, UpdatePolicy
from infra_bot.slack import handle_slack_command, parse_slack_command, run_slack_bot
from infra_bot.state import StateStore


class FakeSlackApp:
    def __init__(self, token):
        self.token = token
        self.handlers = {}

    def command(self, name):
        def decorator(func):
            self.handlers[name] = func
            return func

        return decorator


class FakeSocketModeHandler:
    def __init__(self, app, app_token, command_payload, sink):
        self.app = app
        self.app_token = app_token
        self.command_payload = command_payload
        self.sink = sink

    def start(self):
        def ack(**payload):
            self.sink.update(payload)

        self.app.handlers["/infra-bot"](ack, self.command_payload)


def build_config(tmp_path):
    return AppConfig(
        server_name="web-01",
        update_policy=UpdatePolicy(),
        reboot_policy=RebootPolicy(),
        paths=PathConfig(
            state_file=tmp_path / "state.json",
            reboot_marker_file=tmp_path / "reboot-required",
        ),
        messaging=MessagingConfig(mode="slack"),
        slack=SlackConfig(
            bot_token="xoxb-test",
            app_token="xapp-test",
            allowed_user_ids=["U1"],
            notification_channel_ids=["C1"],
        ),
    )


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("", "/help"),
        ("help", "/help"),
        ("status", "/status"),
        ("updates now", "/updates"),
        ("/lastrun", "/lastrun"),
    ],
)
def test_parse_slack_command_maps_to_internal_commands(text, expected) -> None:
    assert parse_slack_command(text) == expected


def test_handle_slack_command_rejects_unauthorized_user(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)

    response = handle_slack_command("status", "U999", config, store)

    assert response == "Unauthorized."


def test_run_slack_bot_handles_authorized_slash_command(tmp_path, monkeypatch) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    sink = {}

    monkeypatch.setattr("infra_bot.slack.handle_command", lambda text, *_: f"reply:{text}")

    run_slack_bot(
        config,
        store,
        app_factory=FakeSlackApp,
        handler_factory=lambda app, app_token: FakeSocketModeHandler(
            app,
            app_token,
            {"text": "status", "user_id": "U1"},
            sink,
        ),
    )

    assert sink == {"response_type": "ephemeral", "text": "reply:/status"}


def test_run_slack_bot_rejects_unauthorized_slash_command(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    sink = {}

    run_slack_bot(
        config,
        store,
        app_factory=FakeSlackApp,
        handler_factory=lambda app, app_token: FakeSocketModeHandler(
            app,
            app_token,
            {"text": "status", "user_id": "U999"},
            sink,
        ),
    )

    assert sink == {"response_type": "ephemeral", "text": "Unauthorized."}
