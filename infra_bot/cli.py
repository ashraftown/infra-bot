from __future__ import annotations

import argparse
import json
import logging
import sys

from infra_bot.bot import run_polling_bot
from infra_bot.commands import handle_command
from infra_bot.config import DEFAULT_CONFIG_PATH, load_config
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


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    parser = build_parser()
    args = parser.parse_args(argv)
    config = load_config(args.config)
    store = StateStore(config.paths.state_file)
    telegram = TelegramClient(config.telegram.bot_token, timeout_seconds=config.telegram.poll_timeout_seconds)

    if args.command == "run-bot":
        run_polling_bot(config, store, telegram)
        return 0

    if args.command == "run-update":
        result = perform_update(config, store, telegram)
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

