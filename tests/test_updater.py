from __future__ import annotations

from infra_bot.config import AppConfig, MessagingConfig, PathConfig, RebootPolicy, TelegramConfig, UpdatePolicy
from infra_bot.state import StateStore
from infra_bot.updater import (
    CommandResult,
    PackageUpdate,
    _build_success_message,
    parse_upgradable_output,
    perform_update,
)


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


APT_LIST_BEFORE = """\
Listing...
openssl/noble-updates 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
curl/noble-updates 8.5.0-2ubuntu10.2 amd64 [upgradable from: 8.5.0-2ubuntu10.1]
held-pkg/noble-updates 2.0-2 amd64 [upgradable from: 2.0-1]
"""

APT_LIST_AFTER = """\
Listing...
held-pkg/noble-updates 2.0-2 amd64 [upgradable from: 2.0-1]
"""


def test_parse_upgradable_output_extracts_versions() -> None:
    packages = parse_upgradable_output(APT_LIST_BEFORE)
    assert packages == [
        PackageUpdate("openssl", "3.0.13-0ubuntu3.5", "3.0.13-0ubuntu3.4"),
        PackageUpdate("curl", "8.5.0-2ubuntu10.2", "8.5.0-2ubuntu10.1"),
        PackageUpdate("held-pkg", "2.0-2", "2.0-1"),
    ]
    assert packages[0].format_line() == "openssl: 3.0.13-0ubuntu3.4 → 3.0.13-0ubuntu3.5"


def test_build_success_message_includes_package_lines() -> None:
    message = _build_success_message(
        "node1",
        24,
        2,
        [
            "openssl: 3.0.13-0ubuntu3.4 → 3.0.13-0ubuntu3.5",
            "curl: 8.5.0-2ubuntu10.1 → 8.5.0-2ubuntu10.2",
        ],
        False,
    )
    assert message.startswith("[node1] Update completed successfully in 24s. Packages changed: 2.")
    assert "openssl: 3.0.13-0ubuntu3.4 → 3.0.13-0ubuntu3.5" in message
    assert "curl: 8.5.0-2ubuntu10.1 → 8.5.0-2ubuntu10.2" in message


def test_perform_update_success_with_multiple_notifiers(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = DummyNotifier("telegram")
    slack = DummyNotifier("slack")
    list_calls = {"count": 0}

    def runner(cmd, env=None):
        if cmd[:2] == ["apt", "list"]:
            list_calls["count"] += 1
            # First listing is after apt-get update; later listings are post-upgrade.
            output = APT_LIST_BEFORE if list_calls["count"] == 1 else APT_LIST_AFTER
            return CommandResult(cmd, 0, output, "")
        if cmd[:2] == ["apt-get", "update"]:
            return CommandResult(cmd, 0, "", "")
        if cmd[:3] == ["apt-get", "-y", "upgrade"]:
            return CommandResult(cmd, 0, "2 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.", "")
        if cmd[:3] == ["apt-get", "-y", "dist-upgrade"]:
            return CommandResult(cmd, 0, "0 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.", "")
        return CommandResult(cmd, 0, "", "")

    result = perform_update(
        config,
        store,
        notifiers=[telegram, slack],
        command_runner=runner,
        reboot_scheduler=lambda _: None,
    )

    assert result.status == "success"
    assert result.packages_changed == 2
    assert result.package_details == [
        "openssl: 3.0.13-0ubuntu3.4 → 3.0.13-0ubuntu3.5",
        "curl: 8.5.0-2ubuntu10.1 → 8.5.0-2ubuntu10.2",
    ]
    assert result.held_back == 1
    assert len(telegram.messages) >= 2
    assert len(slack.messages) >= 2
    success_messages = [msg for msg in telegram.messages if "completed successfully" in msg]
    assert success_messages
    assert "openssl: 3.0.13-0ubuntu3.4 → 3.0.13-0ubuntu3.5" in success_messages[0]
    assert "held-pkg" not in success_messages[0]

    state = store.load()
    assert state.last_run_package_details == result.package_details


def test_perform_update_records_slack_send_failures(tmp_path) -> None:
    config = build_config(tmp_path)
    store = StateStore(config.paths.state_file)
    telegram = DummyNotifier("telegram")
    slack = DummyNotifier("slack", errors=["C1: boom"])

    def runner(cmd, env=None):
        if cmd[:2] == ["apt", "list"]:
            return CommandResult(cmd, 0, "Listing...\n", "")
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
    assert state.last_run_package_details == []
