from dataclasses import replace

from infra_bot.commands import handle_command
from infra_bot.config import AppConfig, MessagingConfig, PathConfig, RebootPolicy, TelegramConfig, UpdatePolicy
from infra_bot.state import BotState, StateStore


def build_config(tmp_path):
    return AppConfig(
        server_name="web-01",
        update_policy=UpdatePolicy(),
        reboot_policy=RebootPolicy(),
        paths=PathConfig(
            state_file=tmp_path / "state.json",
            reboot_marker_file=tmp_path / "reboot-required",
        ),
        messaging=MessagingConfig(mode="telegram"),
        telegram=TelegramConfig(bot_token="token", allowed_chat_ids=[1]),
    )


def test_help_command(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    response = handle_command("/help", config, store)
    assert "/status" in response


def test_last_run_command(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    state = BotState(
        last_run_at="2026-03-23T00:00:00+00:00",
        last_run_status="success",
        last_run_packages_changed=1,
        last_run_package_details=["openssl: 1.0 → 1.1"],
    )
    store.save(state)
    response = handle_command("/lastrun", config, store)
    assert "2026-03-23T00:00:00+00:00" in response
    assert "success" in response
    assert "openssl: 1.0 → 1.1" in response
