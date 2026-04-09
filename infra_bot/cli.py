from __future__ import annotations

import argparse
import json
import logging
import sys

from infra_bot.bot import run_enabled_bots, run_polling_bot
from infra_bot.commands import handle_command
from infra_bot.config import DEFAULT_CONFIG_PATH, load_config
from infra_bot.notifiers import SlackNotifier, TelegramNotifier
from infra_bot.slack import SlackClient, run_slack_bot
from infra_bot.state import StateStore
from infra_bot.telegram import TelegramClient
from infra_bot.updater import count_pending_updates, perform_update


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="infra-bot")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG_PATH))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("run-bot")
    sub.add_parser("run-update")
    sub.add_parser("status")
    sub.add_parser("pending-updates")
    return parser


def build_notifiers(config):
    notifiers = []
    if config.messaging.mode in {"telegram", "both"}:
        if config.telegram is None:
            raise ValueError("Telegram is not configured")
        telegram = TelegramClient(config.telegram.bot_token, timeout_seconds=config.telegram.poll_timeout_seconds)
        notifiers.append(TelegramNotifier(telegram, config.telegram.allowed_chat_ids))
    if config.messaging.mode in {"slack", "both"}:
        if config.slack is None:
            raise ValueError("Slack is not configured")
        slack = SlackClient(config.slack.bot_token)
        notifiers.append(SlackNotifier(slack, config.slack.notification_channel_ids))
    return notifiers


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    parser = build_parser()
    args = parser.parse_args(argv)
    config = load_config(args.config)
    store = StateStore(config.paths.state_file)

    if args.command == "run-bot":
        telegram_runner = None
        slack_runner = None

        if config.messaging.mode in {"telegram", "both"}:
            if config.telegram is None:
                raise ValueError("Telegram is not configured")
            telegram = TelegramClient(config.telegram.bot_token, timeout_seconds=config.telegram.poll_timeout_seconds)
            telegram_runner = lambda: run_polling_bot(config, store, telegram)

        if config.messaging.mode in {"slack", "both"}:
            if config.slack is None:
                raise ValueError("Slack is not configured")
            slack_runner = lambda: run_slack_bot(config, store)

        run_enabled_bots(config, store, telegram_runner=telegram_runner, slack_runner=slack_runner)
        return 0

    if args.command == "run-update":
        result = perform_update(config, store, notifiers=build_notifiers(config))
        print(json.dumps(result.__dict__, indent=2, sort_keys=True))
        return 0 if result.status == "success" else 1

    if args.command == "status":
        print(handle_command("/status", config, store))
        return 0

    if args.command == "pending-updates":
        pending_count, names = count_pending_updates()
        print(json.dumps({"count": pending_count, "packages": names}, indent=2))
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
