from __future__ import annotations

import logging
import time

from infra_bot.commands import handle_command
from infra_bot.config import AppConfig
from infra_bot.state import StateStore
from infra_bot.telegram import TelegramClient, TelegramError


LOGGER = logging.getLogger(__name__)


def run_polling_bot(
    config: AppConfig,
    store: StateStore,
    telegram: TelegramClient,
    sleep_seconds: int = 2,
) -> None:
    offset: int | None = None
    allowed = set(config.telegram.allowed_chat_ids)
    while True:
        try:
            updates = telegram.get_updates(offset=offset, timeout=config.telegram.poll_timeout_seconds)
            for update in updates:
                offset = update.update_id + 1
                if update.chat_id not in allowed:
                    LOGGER.warning("unauthorized telegram chat id %s", update.chat_id)
                    continue
                reply = handle_command(update.text, config, store)
                telegram.send_message(update.chat_id, reply)
        except TelegramError as exc:
            LOGGER.warning("telegram polling failure: %s", exc)
            state = store.load()
            state.last_telegram_error = str(exc)
            store.save(state)
            time.sleep(sleep_seconds)

