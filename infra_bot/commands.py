from __future__ import annotations

import platform
import subprocess

from infra_bot.config import AppConfig
from infra_bot.reboot import reboot_required
from infra_bot.state import StateStore
from infra_bot.updater import count_pending_updates


def _read_os_release() -> str:
    try:
        with open("/etc/os-release", "r", encoding="utf-8") as handle:
            data = handle.read()
    except FileNotFoundError:
        return platform.platform()
    for line in data.splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip().strip('"')
    return platform.platform()


def _service_health() -> str:
    result = subprocess.run(
        ["systemctl", "is-active", "infra-bot.service"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return "unknown"


def render_help() -> str:
    return (
        "Commands:\n"
        "/start - bot identity and commands\n"
        "/status - server health summary\n"
        "/updates - pending package updates\n"
        "/lastrun - last update run details\n"
        "/help - command list"
    )


def handle_command(text: str, config: AppConfig, store: StateStore) -> str:
    command = text.strip().split()[0].lower()
    state = store.load()

    if command in {"/start", "/help"}:
        return f"{config.server_name}\n{render_help()}"

    if command == "/status":
        pending_count, _ = count_pending_updates()
        os_name = _read_os_release()
        return (
            f"Server: {config.server_name}\n"
            f"Hostname: {platform.node()}\n"
            f"OS: {os_name}\n"
            f"Last run: {state.last_run_status or 'never'} at {state.last_run_at or 'n/a'}\n"
            f"Pending updates: {pending_count}\n"
            f"Reboot required: {'yes' if reboot_required(config.paths.reboot_marker_file) else 'no'}\n"
            f"Service health: {_service_health()}"
        )

    if command == "/updates":
        pending_count, names = count_pending_updates()
        names_text = ", ".join(names) if names else "none"
        return f"Pending updates: {pending_count}\nPackages: {names_text}"

    if command == "/lastrun":
        return (
            f"Last run: {state.last_run_at or 'never'}\n"
            f"Status: {state.last_run_status or 'n/a'}\n"
            f"Duration: {state.last_run_duration_seconds if state.last_run_duration_seconds is not None else 'n/a'}\n"
            f"Packages changed: {state.last_run_packages_changed if state.last_run_packages_changed is not None else 'unknown'}\n"
            f"Error: {state.last_run_error or 'none'}"
        )

    if command == "/reboot":
        return "Reboot is automated only within the maintenance workflow."

    return "Unknown command. Use /help."

