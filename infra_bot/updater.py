from __future__ import annotations

import re
import subprocess
import time
from dataclasses import dataclass, field

from infra_bot.config import AppConfig
from infra_bot.notifiers import Notifier
from infra_bot.reboot import reboot_required, schedule_reboot
from infra_bot.state import BotState, StateStore, utc_now_iso


UPGRADE_COUNT_RE = re.compile(r"(\d+)\s+upgraded")
# Example: openssl/noble-updates 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
UPGRADABLE_LINE_RE = re.compile(
    r"^(?P<name>[^/\s]+)/\S+\s+(?P<new>\S+)\s+\S+\s+\[upgradable from: (?P<old>[^\]]+)\]"
)
UPGRADABLE_NAME_RE = re.compile(r"^(?P<name>[^/\s]+)/")

# Stay under Telegram's 4096-char limit with headroom for formatting.
MAX_NOTIFY_CHARS = 3900
MAX_PACKAGE_LINES_IN_NOTIFY = 50
MAX_PACKAGE_LINES_IN_COMMAND = 30


@dataclass(frozen=True)
class PackageUpdate:
    name: str
    new_version: str | None = None
    old_version: str | None = None

    def format_line(self) -> str:
        if self.old_version and self.new_version:
            return f"{self.name}: {self.old_version} → {self.new_version}"
        if self.new_version:
            return f"{self.name}: → {self.new_version}"
        return self.name


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
    package_details: list[str] = field(default_factory=list)


def run_command(cmd: list[str], env: dict[str, str] | None = None) -> CommandResult:
    proc = subprocess.run(cmd, check=False, capture_output=True, text=True, env=env)
    return CommandResult(cmd=cmd, returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)


def parse_upgradable_output(output: str) -> list[PackageUpdate]:
    packages: list[PackageUpdate] = []
    seen: set[str] = set()
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("Listing..."):
            continue
        match = UPGRADABLE_LINE_RE.match(line)
        if match:
            name = match.group("name")
            if name in seen:
                continue
            seen.add(name)
            packages.append(
                PackageUpdate(
                    name=name,
                    new_version=match.group("new"),
                    old_version=match.group("old").strip(),
                )
            )
            continue
        name_match = UPGRADABLE_NAME_RE.match(line)
        if name_match:
            name = name_match.group("name")
            if name in seen:
                continue
            seen.add(name)
            packages.append(PackageUpdate(name=name))
    return packages


def list_upgradable_packages(command_runner=run_command) -> list[PackageUpdate]:
    result = command_runner(
        ["apt", "list", "--upgradable"],
        {"LANG": "C", "LC_ALL": "C"},
    )
    if result.returncode != 0:
        return []
    # apt may print the listing on stdout; some environments mix warnings into stderr.
    combined = result.stdout or ""
    if not combined.strip() and result.stderr:
        combined = result.stderr
    return parse_upgradable_output(combined)


def count_pending_updates(command_runner=run_command) -> tuple[int, list[str]]:
    packages = list_upgradable_packages(command_runner)
    return len(packages), [package.format_line() for package in packages[:10]]


def format_package_lines(packages: list[PackageUpdate], *, max_lines: int | None = None) -> list[str]:
    if max_lines is None:
        return [package.format_line() for package in packages]
    lines = [package.format_line() for package in packages[:max_lines]]
    remaining = len(packages) - max_lines
    if remaining > 0:
        lines.append(f"... and {remaining} more")
    return lines


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


def _diff_upgraded_packages(
    before: list[PackageUpdate], after: list[PackageUpdate]
) -> list[PackageUpdate]:
    remaining = {package.name for package in after}
    return [package for package in before if package.name not in remaining]


def _build_success_message(
    server_name: str,
    duration: int,
    packages_changed: int | None,
    package_details: list[str],
    reboot_needed: bool,
) -> str:
    suffix = "reboot scheduled" if reboot_needed else "no reboot required"
    header = (
        f"[{server_name}] Update completed successfully in {duration}s. "
        f"Packages changed: {packages_changed if packages_changed is not None else 'unknown'}. {suffix}."
    )
    if not package_details:
        return header

    lines = package_details[:MAX_PACKAGE_LINES_IN_NOTIFY]
    remaining = len(package_details) - len(lines)
    body_lines = list(lines)
    if remaining > 0:
        body_lines.append(f"... and {remaining} more")

    message = header + "\n" + "\n".join(body_lines)
    if len(message) <= MAX_NOTIFY_CHARS:
        return message

    # Truncate package lines until the message fits.
    kept: list[str] = []
    omitted = len(package_details)
    for line in package_details:
        candidate_tail = "\n".join(kept + [line])
        suffix_note = f"\n... and {omitted - len(kept) - 1} more" if omitted > len(kept) + 1 else ""
        candidate = f"{header}\n{candidate_tail}{suffix_note}"
        if len(candidate) > MAX_NOTIFY_CHARS:
            break
        kept.append(line)
    if not kept:
        return header
    omitted_count = len(package_details) - len(kept)
    if omitted_count > 0:
        return f"{header}\n" + "\n".join(kept) + f"\n... and {omitted_count} more"
    return f"{header}\n" + "\n".join(kept)


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
    package_details: list[str] = []
    pending_before: list[PackageUpdate] = []
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
            state.last_run_package_details = []
            state.last_run_error = error
            state.reboot_required = False
            store.save(state)
            if active_notifiers:
                errors_by_provider = _notify(active_notifiers, f"[{config.server_name}] Update failed: {error}")
                if _apply_notifier_errors(state, errors_by_provider):
                    store.save(state)
            return UpdateResult(
                "failed",
                started_at,
                duration,
                packages_changed,
                False,
                error,
                held_back,
                package_details,
            )
        # Snapshot candidates after indexes refresh so old→new versions are current.
        if cmd == ["apt-get", "update"]:
            pending_before = list_upgradable_packages(command_runner)
        if cmd[0:3] == ["apt-get", "-y", "upgrade"] or cmd[0:3] == ["apt-get", "-y", "dist-upgrade"]:
            parsed = _parse_package_count(result.stdout)
            if parsed is not None:
                packages_changed = (packages_changed or 0) + parsed

    pending_after = list_upgradable_packages(command_runner)
    upgraded_packages = _diff_upgraded_packages(pending_before, pending_after)
    package_details = format_package_lines(upgraded_packages)
    if packages_changed is None and package_details:
        packages_changed = len(package_details)
    held_back = len(pending_after) if pending_after else 0

    reboot_needed = reboot_required(config.paths.reboot_marker_file)
    duration = int(time.monotonic() - started)
    state.last_run_at = started_at
    state.last_run_status = "success"
    state.last_run_duration_seconds = duration
    state.last_run_packages_changed = packages_changed
    state.last_run_package_details = package_details
    state.last_run_error = None
    state.reboot_required = reboot_needed
    if reboot_needed and config.reboot_policy.mode == "scheduled_if_required":
        reboot_scheduler(config.reboot_policy.grace_minutes)
        state.last_reboot_scheduled_at = utc_now_iso()
    store.save(state)

    if active_notifiers:
        success_message = _build_success_message(
            config.server_name,
            duration,
            packages_changed,
            package_details,
            reboot_needed,
        )
        errors_by_provider = _notify(active_notifiers, success_message)
        if reboot_needed:
            pre_reboot = f"[{config.server_name}] Reboot scheduled in {config.reboot_policy.grace_minutes} minutes."
            reboot_errors = _notify(active_notifiers, pre_reboot)
            for provider, provider_errors in reboot_errors.items():
                errors_by_provider.setdefault(provider, []).extend(provider_errors)
        if _apply_notifier_errors(state, errors_by_provider):
            store.save(state)

    return UpdateResult(
        "success",
        started_at,
        duration,
        packages_changed,
        reboot_needed,
        None,
        held_back,
        package_details,
    )
