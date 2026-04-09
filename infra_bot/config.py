from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


DEFAULT_CONFIG_PATH = Path("/etc/infra-bot/config.yaml")


@dataclass
class MessagingConfig:
    mode: str = "telegram"


@dataclass
class TelegramConfig:
    bot_token: str
    allowed_chat_ids: list[int]
    poll_timeout_seconds: int = 30


@dataclass
class SlackConfig:
    bot_token: str
    app_token: str
    allowed_user_ids: list[str]
    notification_channel_ids: list[str]
    command_name: str = "/infra-bot"


@dataclass
class UpdatePolicy:
    schedule: str = "Sun 02:00"
    stagger_minutes: int = 0
    use_dist_upgrade: bool = True
    autoremove: bool = True


@dataclass
class RebootPolicy:
    mode: str = "scheduled_if_required"
    grace_minutes: int = 5


@dataclass
class PathConfig:
    state_file: Path = Path("/var/lib/infra-bot/state.json")
    reboot_marker_file: Path = Path("/var/run/reboot-required")


@dataclass
class AppConfig:
    server_name: str
    update_policy: UpdatePolicy
    reboot_policy: RebootPolicy
    paths: PathConfig
    messaging: MessagingConfig = field(default_factory=MessagingConfig)
    telegram: TelegramConfig | None = None
    slack: SlackConfig | None = None


def _require_mapping(payload: Any, label: str) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError(f"{label} must be a mapping")
    return payload


def _parse_string_list(payload: Any, label: str) -> list[str]:
    if not isinstance(payload, list) or not payload:
        raise ValueError(f"{label} must be a non-empty list")
    values = [str(item).strip() for item in payload if str(item).strip()]
    if not values:
        raise ValueError(f"{label} must be a non-empty list")
    return values


def _provider_enabled(mode: str, provider: str) -> bool:
    return mode == provider or mode == "both"


def load_config(path: str | Path = DEFAULT_CONFIG_PATH) -> AppConfig:
    config_path = Path(path)
    with config_path.open("r", encoding="utf-8") as handle:
        raw = yaml.safe_load(handle) or {}

    root = _require_mapping(raw, "config")
    messaging_raw = _require_mapping(root.get("messaging", {}), "messaging")
    update_raw = _require_mapping(root.get("update_policy", {}), "update_policy")
    reboot_raw = _require_mapping(root.get("reboot_policy", {}), "reboot_policy")
    paths_raw = _require_mapping(root.get("paths", {}), "paths")

    server_name = str(root.get("server_name", "")).strip()
    if not server_name:
        raise ValueError("server_name is required")

    mode = str(messaging_raw.get("mode", "telegram")).strip().lower() or "telegram"
    if mode not in {"telegram", "slack", "both"}:
        raise ValueError("messaging.mode must be one of: telegram, slack, both")

    telegram_config: TelegramConfig | None = None
    if _provider_enabled(mode, "telegram"):
        telegram_raw = _require_mapping(root.get("telegram"), "telegram")
        bot_token = str(telegram_raw.get("bot_token", "")).strip()
        if not bot_token:
            raise ValueError("telegram.bot_token is required")

        allowed_chat_ids = telegram_raw.get("allowed_chat_ids")
        if not isinstance(allowed_chat_ids, list) or not allowed_chat_ids:
            raise ValueError("telegram.allowed_chat_ids must be a non-empty list")

        telegram_config = TelegramConfig(
            bot_token=bot_token,
            allowed_chat_ids=[int(value) for value in allowed_chat_ids],
            poll_timeout_seconds=int(telegram_raw.get("poll_timeout_seconds", 30)),
        )

    slack_config: SlackConfig | None = None
    if _provider_enabled(mode, "slack"):
        slack_raw = _require_mapping(root.get("slack"), "slack")
        slack_bot_token = str(slack_raw.get("bot_token", "")).strip()
        if not slack_bot_token:
            raise ValueError("slack.bot_token is required")

        slack_app_token = str(slack_raw.get("app_token", "")).strip()
        if not slack_app_token:
            raise ValueError("slack.app_token is required")

        allowed_user_ids = _parse_string_list(slack_raw.get("allowed_user_ids"), "slack.allowed_user_ids")
        notification_channel_ids = _parse_string_list(
            slack_raw.get("notification_channel_ids"),
            "slack.notification_channel_ids",
        )
        command_name = str(slack_raw.get("command_name", "/infra-bot")).strip() or "/infra-bot"
        if not command_name.startswith("/"):
            raise ValueError("slack.command_name must start with '/'")

        slack_config = SlackConfig(
            bot_token=slack_bot_token,
            app_token=slack_app_token,
            allowed_user_ids=allowed_user_ids,
            notification_channel_ids=notification_channel_ids,
            command_name=command_name,
        )

    return AppConfig(
        server_name=server_name,
        messaging=MessagingConfig(mode=mode),
        telegram=telegram_config,
        slack=slack_config,
        update_policy=UpdatePolicy(
            schedule=str(update_raw.get("schedule", "Sun 02:00")),
            stagger_minutes=int(update_raw.get("stagger_minutes", 0)),
            use_dist_upgrade=bool(update_raw.get("use_dist_upgrade", True)),
            autoremove=bool(update_raw.get("autoremove", True)),
        ),
        reboot_policy=RebootPolicy(
            mode=str(reboot_raw.get("mode", "scheduled_if_required")),
            grace_minutes=int(reboot_raw.get("grace_minutes", 5)),
        ),
        paths=PathConfig(
            state_file=Path(paths_raw.get("state_file", "/var/lib/infra-bot/state.json")),
            reboot_marker_file=Path(paths_raw.get("reboot_marker_file", "/var/run/reboot-required")),
        ),
    )
