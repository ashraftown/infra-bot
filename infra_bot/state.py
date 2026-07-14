from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


LOGGER = logging.getLogger(__name__)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


@dataclass
class BotState:
    last_run_at: str | None = None
    last_run_status: str | None = None
    last_run_duration_seconds: int | None = None
    last_run_packages_changed: int | None = None
    last_run_package_details: list[str] = field(default_factory=list)
    last_run_error: str | None = None
    reboot_required: bool = False
    last_reboot_scheduled_at: str | None = None
    last_telegram_error: str | None = None
    last_slack_error: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        payload = {
            "last_run_at": self.last_run_at,
            "last_run_status": self.last_run_status,
            "last_run_duration_seconds": self.last_run_duration_seconds,
            "last_run_packages_changed": self.last_run_packages_changed,
            "last_run_package_details": list(self.last_run_package_details),
            "last_run_error": self.last_run_error,
            "reboot_required": self.reboot_required,
            "last_reboot_scheduled_at": self.last_reboot_scheduled_at,
            "last_telegram_error": self.last_telegram_error,
            "last_slack_error": self.last_slack_error,
        }
        payload.update(self.extra)
        return payload

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "BotState":
        known = {
            "last_run_at",
            "last_run_status",
            "last_run_duration_seconds",
            "last_run_packages_changed",
            "last_run_package_details",
            "last_run_error",
            "reboot_required",
            "last_reboot_scheduled_at",
            "last_telegram_error",
            "last_slack_error",
        }
        raw_details = payload.get("last_run_package_details") or []
        if not isinstance(raw_details, list):
            raw_details = []
        package_details = [str(item) for item in raw_details]
        extra = {key: value for key, value in payload.items() if key not in known}
        return cls(
            last_run_at=payload.get("last_run_at"),
            last_run_status=payload.get("last_run_status"),
            last_run_duration_seconds=payload.get("last_run_duration_seconds"),
            last_run_packages_changed=payload.get("last_run_packages_changed"),
            last_run_package_details=package_details,
            last_run_error=payload.get("last_run_error"),
            reboot_required=bool(payload.get("reboot_required", False)),
            last_reboot_scheduled_at=payload.get("last_reboot_scheduled_at"),
            last_telegram_error=payload.get("last_telegram_error"),
            last_slack_error=payload.get("last_slack_error"),
            extra=extra,
        )


class StateStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)

    def load(self) -> BotState:
        if not self.path.exists():
            return BotState()
        try:
            raw = self.path.read_text(encoding="utf-8").strip()
        except OSError as exc:
            LOGGER.warning("failed to read state file %s: %s", self.path, exc)
            return BotState()
        if not raw:
            # Empty file (often from a crashed non-atomic write). Start fresh.
            LOGGER.warning("state file %s is empty; using defaults", self.path)
            return BotState()
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            LOGGER.warning("state file %s is invalid JSON (%s); using defaults", self.path, exc)
            return BotState()
        if not isinstance(payload, dict):
            LOGGER.warning("state file %s is not a JSON object; using defaults", self.path)
            return BotState()
        return BotState.from_dict(payload)

    def save(self, state: BotState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(state.to_dict(), indent=2, sort_keys=True) + "\n"
        # Atomic replace avoids truncated/empty state.json if the process dies mid-write.
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.",
            suffix=".tmp",
            dir=str(self.path.parent),
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp_name, self.path)
        except Exception:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise
