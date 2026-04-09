from __future__ import annotations

import re
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

from infra_bot.config import AppConfig
from infra_bot.notifiers import Notifier
from infra_bot.reboot import reboot_required, schedule_reboot
from infra_bot.state import BotState, StateStore, utc_now_iso


UPGRADE_COUNT_RE = re.compile(r"(\d+)\s+upgraded")


@dataclass
class CommandResult:
    cmd: list[str]
    returncode: int
    stdout: str
    stderr: str


@dataclass
class UpdateResult:
    status: str
    started_at: str
    duration_seconds: int
    packages_changed: int | None
    reboot_required: bool
    error: str | None
    held_back: int | None


def run_command(cmd: list[str], env: dict[str, str] | None = None) -> CommandResult:
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True, env=env)
    return CommandResult(cmd=cmd, returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)


def count_pending_updates() -> tuple[int, list[str]]:
    result = run_command(["apt", "list", "--upgradable"])
    if result.returncode != 0:
        return 0, []
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    package_lines = [line for line in lines if not line.startswith("Listing...")]
    names = [line.split("/", 1)[0] for line in package_lines]
    return len(names), names[:10]


def _parse_package_count(output: str) -> int | None:
    match = UPGRADE_COUNT_RE.search(output)
    if match:
        return int(match.group(1))
    return None


def _apply_notifier_errors(state: BotState, errors_by_provider: dict[str, list[str]]) -> bool:
    changed = False

    telegram_errors = errors_by_provider.get("telegram")
    if telegram_errors:
        state.last_telegram_error = "; ".join(telegram_errors)
        changed = True

    slack_errors = errors_by_provider.get("slack")
    if slack_errors:
        state.last_slack_error = "; ".join(slack_errors)
        changed = True

    return changed


def _notify(notifiers: list[Notifier], text: str) -> dict[str, list[str]]:
    errors: dict[str, list[str]] = {}
    for notifier in notifiers:
        provider_errors = notifier.send(text)
        if provider_errors:
            errors[notifier.name] = provider_errors
    return errors


def perform_update(
    config: AppConfig,
    store: StateStore,
    notifiers: list[Notifier] | None = None,
    command_runner=run_command,
    reboot_scheduler=schedule_reboot,
) -> UpdateResult:
    state = store.load()
    started_at = utc_now_iso()
    started = time.monotonic()
    active_notifiers = notifiers or []

    if active_notifiers:
        errors_by_provider = _notify(active_notifiers, f"[{config.server_name}] Update started at {started_at}")
        if _apply_notifier_errors(state, errors_by_provider):
            store.save(state)

    steps = [
        (["apt-get", "update"], None),
        (["apt-get", "-y", "upgrade"], {"DEBIAN_FRONTEND": "noninteractive"}),
    ]
    if config.update_policy.use_dist_upgrade:
        steps.append((["apt-get", "-y", "dist-upgrade"], {"DEBIAN_FRONTEND": "noninteractive"}))
    if config.update_policy.autoremove:
        steps.append((["apt-get", "-y", "autoremove", "--purge"], None))

    packages_changed: int | None = None
    error: str | None = None
    held_back = None

    for cmd, extra_env in steps:
        env = None
        if extra_env:
            env = dict(extra_env)
        result = command_runner(cmd, env=env)
        if result.returncode != 0:
            error = f"{' '.join(cmd)} failed: {result.stderr.strip() or result.stdout.strip()}"
            duration = int(time.monotonic() - started)
            state.last_run_at = started_at
            state.last_run_status = "failed"
            state.last_run_duration_seconds = duration
            state.last_run_packages_changed = packages_changed
            state.last_run_error = error
            state.reboot_required = False
            store.save(state)
            if active_notifiers:
                errors_by_provider = _notify(active_notifiers, f"[{config.server_name}] Update failed: {error}")
                if _apply_notifier_errors(state, errors_by_provider):
                    store.save(state)
            return UpdateResult("failed", started_at, duration, packages_changed, False, error, held_back)
        if cmd[0:3] == ["apt-get", "-y", "upgrade"] or cmd[0:3] == ["apt-get", "-y", "dist-upgrade"]:
            parsed = _parse_package_count(result.stdout)
            if parsed is not None:
                packages_changed = (packages_changed or 0) + parsed

    reboot_needed = reboot_required(config.paths.reboot_marker_file)
    duration = int(time.monotonic() - started)
    state.last_run_at = started_at
    state.last_run_status = "success"
    state.last_run_duration_seconds = duration
    state.last_run_packages_changed = packages_changed
    state.last_run_error = None
    state.reboot_required = reboot_needed
    if reboot_needed and config.reboot_policy.mode == "scheduled_if_required":
        reboot_scheduler(config.reboot_policy.grace_minutes)
        state.last_reboot_scheduled_at = utc_now_iso()
    store.save(state)

    if active_notifiers:
        suffix = "reboot scheduled" if reboot_needed else "no reboot required"
        errors_by_provider = _notify(
            active_notifiers,
            f"[{config.server_name}] Update completed successfully in {duration}s. "
            f"Packages changed: {packages_changed if packages_changed is not None else 'unknown'}. {suffix}.",
        )
        if reboot_needed:
            pre_reboot = f"[{config.server_name}] Reboot scheduled in {config.reboot_policy.grace_minutes} minutes."
            reboot_errors = _notify(active_notifiers, pre_reboot)
            for provider, provider_errors in reboot_errors.items():
                errors_by_provider.setdefault(provider, []).extend(provider_errors)
        if _apply_notifier_errors(state, errors_by_provider):
            store.save(state)

    return UpdateResult("success", started_at, duration, packages_changed, reboot_needed, None, held_back)
