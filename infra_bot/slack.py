from __future__ import annotations

import logging
from typing import Any, Callable

from infra_bot.commands import handle_command
from infra_bot.config import AppConfig
from infra_bot.state import StateStore


LOGGER = logging.getLogger(__name__)


class SlackError(RuntimeError):
    pass


class SlackClient:
    def __init__(self, bot_token: str, web_client: Any | None = None):
        self.bot_token = bot_token
        if web_client is None:
            try:
                from slack_sdk import WebClient
            except ImportError as exc:
                raise SlackError("slack-bolt is required for Slack support") from exc
            web_client = WebClient(token=bot_token)
        self._client = web_client

    def send_message(self, channel_id: str, text: str) -> None:
        try:
            self._client.chat_postMessage(channel=channel_id, text=text)
        except Exception as exc:
            raise SlackError(str(exc)) from exc

    def send_many(self, channel_ids: list[str], text: str) -> list[str]:
        errors: list[str] = []
        for channel_id in channel_ids:
            try:
                self.send_message(channel_id, text)
            except SlackError as exc:
                LOGGER.warning("slack send failed for channel %s: %s", channel_id, exc)
                errors.append(f"{channel_id}: {exc}")
        return errors


def parse_slack_command(text: str) -> str:
    raw = text.strip()
    if not raw:
        return "/help"

    command = raw.split()[0].lower().lstrip("/")
    if not command:
        return "/help"
    return f"/{command}"


def handle_slack_command(text: str, user_id: str, config: AppConfig, store: StateStore) -> str:
    slack = config.slack
    if slack is None:
        raise ValueError("Slack is not configured")

    if user_id not in set(slack.allowed_user_ids):
        return "Unauthorized."

    return handle_command(parse_slack_command(text), config, store)


def run_slack_bot(
    config: AppConfig,
    store: StateStore,
    app_factory: Callable[..., Any] | None = None,
    handler_factory: Callable[..., Any] | None = None,
) -> None:
    slack = config.slack
    if slack is None:
        raise ValueError("Slack is not configured")

    if app_factory is None or handler_factory is None:
        try:
            from slack_bolt import App as SlackApp
            from slack_bolt.adapter.socket_mode import SocketModeHandler
        except ImportError as exc:
            raise SlackError("slack-bolt is required for Slack support") from exc
        app_factory = app_factory or SlackApp
        handler_factory = handler_factory or SocketModeHandler

    app = app_factory(token=slack.bot_token)

    @app.command(slack.command_name)
    def _handle_command(ack: Callable[..., Any], command: dict[str, Any]) -> None:
        response = handle_slack_command(str(command.get("text", "")), str(command.get("user_id", "")), config, store)
        ack(response_type="ephemeral", text=response)

    try:
        handler = handler_factory(app, slack.app_token)
        handler.start()
    except Exception as exc:
        raise SlackError(str(exc)) from exc
