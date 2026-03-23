from pathlib import Path

from infra_bot.config import load_config


def test_load_config(tmp_path: Path) -> None:
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
    assert config.server_name == "web-01"
    assert config.telegram.allowed_chat_ids == [1, 2]
    assert str(config.paths.state_file) == "/tmp/state.json"

