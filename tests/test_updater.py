from infra_bot.config import AppConfig, PathConfig, RebootPolicy, TelegramConfig, UpdatePolicy
from infra_bot.state import StateStore
from infra_bot.updater import CommandResult, perform_update


class DummyTelegram:
    def __init__(self):
        self.messages = []

    def send_many(self, chat_ids, text):
        self.messages.append((tuple(chat_ids), text))
        return []


def build_config(tmp_path):
    return AppConfig(
        server_name="web-01",
        telegram=TelegramConfig(bot_token="token", allowed_chat_ids=[123]),
        update_policy=UpdatePolicy(),
        reboot_policy=RebootPolicy(mode="scheduled_if_required", grace_minutes=5),
        paths=PathConfig(
            state_file=tmp_path / "state.json",
            reboot_marker_file=tmp_path / "reboot-required",
        ),
    )


def test_perform_update_success(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = DummyTelegram()

    def runner(cmd, env=None):
        if cmd[:2] == ["apt-get", "update"]:
            return CommandResult(cmd, 0, "", "")
        return CommandResult(cmd, 0, "1 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.", "")

    result = perform_update(config, store, telegram=telegram, command_runner=runner, reboot_scheduler=lambda _: None)
    assert result.status == "success"
    assert result.packages_changed == 2
    assert len(telegram.messages) >= 2


def test_perform_update_failure(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = DummyTelegram()

    def runner(cmd, env=None):
        if cmd[:2] == ["apt-get", "update"]:
            return CommandResult(cmd, 1, "", "boom")
        return CommandResult(cmd, 0, "", "")

    result = perform_update(config, store, telegram=telegram, command_runner=runner, reboot_scheduler=lambda _: None)
    assert result.status == "failed"
    assert "boom" in (result.error or "")

