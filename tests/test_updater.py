from __future__ import annotations

from infra_bot.config import AppConfig, MessagingConfig, PathConfig, RebootPolicy, TelegramConfig, UpdatePolicy
from infra_bot.state import StateStore
from infra_bot.updater import CommandResult, perform_update


class DummyNotifier:
    def __init__(self, name: str, errors: list[str] | None = None):
        self.name = name
        self.errors = errors or []
        self.messages: list[str] = []

    def send(self, text):
        self.messages.append(text)
        return list(self.errors)


def build_config(tmp_path):
    return AppConfig(
        server_name="web-01",
        update_policy=UpdatePolicy(),
        reboot_policy=RebootPolicy(mode="scheduled_if_required", grace_minutes=5),
        paths=PathConfig(
            state_file=tmp_path / "state.json",
            reboot_marker_file=tmp_path / "reboot-required",
        ),
        messaging=MessagingConfig(mode="both"),
        telegram=TelegramConfig(bot_token="token", allowed_chat_ids=[123]),
    )


def test_perform_update_success_with_multiple_notifiers(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = DummyNotifier("telegram")
    slack = DummyNotifier("slack")

    def runner(cmd, env=None):
        if cmd[:2] == ["apt-get", "update"]:
            return CommandResult(cmd, 0, "", "")
        return CommandResult(cmd, 0, "1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.", "")

    result = perform_update(
        config,
        store,
        notifiers=[telegram, slack],
        command_runner=runner,
        reboot_scheduler=lambda _: None,
    )

    assert result.status == "success"
    assert result.packages_changed == 2
    assert len(telegram.messages) >= 2
    assert len(slack.messages) >= 2


def test_perform_update_records_slack_send_failures(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = DummyNotifier("telegram")
    slack = DummyNotifier("slack", errors=["C1: boom"])

    def runner(cmd, env=None):
        if cmd[:2] == ["apt-get", "update"]:
            return CommandResult(cmd, 1, "", "boom")
        return CommandResult(cmd, 0, "", "")

    result = perform_update(
        config,
        store,
        notifiers=[telegram, slack],
        command_runner=runner,
        reboot_scheduler=lambda _: None,
    )

    state = store.load()
    assert result.status == "failed"
    assert "boom" in (result.error or "")
    assert state.last_slack_error == "C1: boom"
