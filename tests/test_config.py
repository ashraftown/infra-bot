from pathlib import Path

import pytest

from infra_bot.config import load_config


def test_load_config_supports_legacy_telegram_only_shape(tmp_path: Path) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        """
server_name: web-01
telegram:
  bot_token: "token"
  allowed_chat_ids: [1, 2]
paths:
  state_file: "/tmp/state.json"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    config = load_config(config_path)

    assert config.messaging.mode == "telegram"
    assert config.telegram is not None
    assert config.telegram.allowed_chat_ids == [1, 2]
    assert config.slack is None
    assert str(config.paths.state_file) == "/tmp/state.json"


def test_load_config_supports_slack_mode(tmp_path: Path) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        """
server_name: web-01
messaging:
  mode: "slack"
slack:
  bot_token: "xoxb-test"
  app_token: "xapp-test"
  allowed_user_ids: ["U1"]
  notification_channel_ids: ["C1"]
paths:
  state_file: "/tmp/state.json"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    config = load_config(config_path)

    assert config.messaging.mode == "slack"
    assert config.telegram is None
    assert config.slack is not None
    assert config.slack.allowed_user_ids == ["U1"]
    assert config.slack.notification_channel_ids == ["C1"]
    assert config.slack.command_name == "/infra-bot"


def test_load_config_supports_both_mode(tmp_path: Path) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        """
server_name: web-01
messaging:
  mode: "both"
telegram:
  bot_token: "token"
  allowed_chat_ids: [1]
slack:
  bot_token: "xoxb-test"
  app_token: "xapp-test"
  allowed_user_ids: ["U1"]
  notification_channel_ids: ["C1"]
paths:
  state_file: "/tmp/state.json"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    config = load_config(config_path)

    assert config.messaging.mode == "both"
    assert config.telegram is not None
    assert config.slack is not None


def test_load_config_rejects_missing_required_telegram_section(tmp_path: Path) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        """
server_name: web-01
messaging:
  mode: "both"
slack:
  bot_token: "xoxb-test"
  app_token: "xapp-test"
  allowed_user_ids: ["U1"]
  notification_channel_ids: ["C1"]
""".strip()
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="telegram must be a mapping"):
        load_config(config_path)


def test_load_config_rejects_missing_required_slack_section(tmp_path: Path) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        """
server_name: web-01
messaging:
  mode: "slack"
""".strip()
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="slack must be a mapping"):
        load_config(config_path)


def test_load_config_rejects_empty_slack_lists(tmp_path: Path) -> None:
    config_path = tmp_path / "config.yaml"
    config_path.write_text(
        """
server_name: web-01
messaging:
  mode: "slack"
slack:
  bot_token: "xoxb-test"
  app_token: "xapp-test"
  allowed_user_ids: []
  notification_channel_ids: ["C1"]
""".strip()
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="slack.allowed_user_ids must be a non-empty list"):
        load_config(config_path)
