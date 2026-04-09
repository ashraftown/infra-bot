import pytest

from infra_bot.bot import run_enabled_bots, run_polling_bot
from infra_bot.config import AppConfig, MessagingConfig, PathConfig, RebootPolicy, TelegramConfig, UpdatePolicy
from infra_bot.state import StateStore
from infra_bot.telegram import TelegramError


class StopLoop(Exception):
    pass


class TimeoutThenStopTelegram:
    def __init__(self):
        self.calls = 0

    def get_updates(self, offset=None, timeout=30):
        self.calls += 1
        raise TelegramError("timed out")


def build_config(tmp_path, mode="telegram"):
    telegram = TelegramConfig(bot_token="token", allowed_chat_ids=[123]) if mode in {"telegram", "both"} else None
    return AppConfig(
        server_name="web-01",
        update_policy=UpdatePolicy(),
        reboot_policy=RebootPolicy(),
        paths=PathConfig(
            state_file=tmp_path / "state.json",
            reboot_marker_file=tmp_path / "reboot-required",
        ),
        messaging=MessagingConfig(mode=mode),
        telegram=telegram,
    )


def test_run_polling_bot_persists_telegram_errors(tmp_path, monkeypatch) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = TimeoutThenStopTelegram()

    def fake_sleep(seconds):
        raise StopLoop()

    monkeypatch.setattr("infra_bot.bot.time.sleep", fake_sleep)

    with pytest.raises(StopLoop):
        run_polling_bot(config, store, telegram, sleep_seconds=0)

    state = store.load()
    assert state.last_telegram_error == "timed out"
    assert telegram.calls == 1


def test_run_enabled_bots_starts_only_telegram_for_telegram_mode(tmp_path) -> None:
    config = build_config(tmp_path, mode="telegram")
    store = StateStore(config.paths.state_file)
    calls = []

    run_enabled_bots(
        config,
        store,
        telegram_runner=lambda: calls.append("telegram"),
        slack_runner=lambda: calls.append("slack"),
    )

    assert calls == ["telegram"]


def test_run_enabled_bots_starts_only_slack_for_slack_mode(tmp_path) -> None:
    config = build_config(tmp_path, mode="slack")
    store = StateStore(config.paths.state_file)
    calls = []

    run_enabled_bots(
        config,
        store,
        telegram_runner=lambda: calls.append("telegram"),
        slack_runner=lambda: calls.append("slack"),
    )

    assert calls == ["slack"]


def test_run_enabled_bots_starts_both_for_both_mode(tmp_path) -> None:
    config = build_config(tmp_path, mode="both")
    store = StateStore(config.paths.state_file)
    calls = []

    run_enabled_bots(
        config,
        store,
        telegram_runner=lambda: calls.append("telegram"),
        slack_runner=lambda: calls.append("slack"),
    )

    assert sorted(calls) == ["slack", "telegram"]
