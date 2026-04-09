from __future__ import annotations

import logging
import threading
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
    if config.telegram is None:
        raise ValueError("Telegram is not configured")

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


def _persist_runtime_error(store: StateStore, provider: str, error: Exception) -> None:
    state = store.load()
    if provider == "telegram":
        state.last_telegram_error = str(error)
    elif provider == "slack":
        state.last_slack_error = str(error)
    store.save(state)


def run_enabled_bots(
    config: AppConfig,
    store: StateStore,
    telegram_runner=None,
    slack_runner=None,
) -> None:
    mode = config.messaging.mode

    if mode == "telegram":
        if telegram_runner is None:
            raise ValueError("Telegram runner is required for telegram mode")
        telegram_runner()
        return

    if mode == "slack":
        if slack_runner is None:
            raise ValueError("Slack runner is required for slack mode")
        slack_runner()
        return

    runners = []
    if telegram_runner is None or slack_runner is None:
        raise ValueError("Telegram and Slack runners are required for both mode")
    runners.append(("telegram", telegram_runner))
    runners.append(("slack", slack_runner))

    errors: list[Exception] = []
    lock = threading.Lock()

    def _run(provider: str, runner) -> None:
        try:
            runner()
        except Exception as exc:  # pragma: no cover - guarded by unit tests via injected runners
            LOGGER.exception("%s bot exited with error", provider)
            _persist_runtime_error(store, provider, exc)
            with lock:
                errors.append(exc)

    threads = [threading.Thread(target=_run, args=(provider, runner), name=f"{provider}-bot") for provider, runner in runners]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    if errors:
        raise errors[0]
