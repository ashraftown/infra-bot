from __future__ import annotations

import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


@dataclass
class BotState:
    last_run_at: str | None = None
    last_run_status: str | None = None
    last_run_duration_seconds: int | None = None
    last_run_packages_changed: int | None = None
    last_run_error: str | None = None
    reboot_required: bool = False
    last_reboot_scheduled_at: str | None = None
    last_telegram_error: str | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        payload = {
            "last_run_at": self.last_run_at,
            "last_run_status": self.last_run_status,
            "last_run_duration_seconds": self.last_run_duration_seconds,
            "last_run_packages_changed": self.last_run_packages_changed,
            "last_run_error": self.last_run_error,
            "reboot_required": self.reboot_required,
            "last_reboot_scheduled_at": self.last_reboot_scheduled_at,
            "last_telegram_error": self.last_telegram_error,
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
            "last_run_error",
            "reboot_required",
            "last_reboot_scheduled_at",
            "last_telegram_error",
        }
        extra = {key: value for key, value in payload.items() if key not in known}
        return cls(
            last_run_at=payload.get("last_run_at"),
            last_run_status=payload.get("last_run_status"),
            last_run_duration_seconds=payload.get("last_run_duration_seconds"),
            last_run_packages_changed=payload.get("last_run_packages_changed"),
            last_run_error=payload.get("last_run_error"),
            reboot_required=bool(payload.get("reboot_required", False)),
            last_reboot_scheduled_at=payload.get("last_reboot_scheduled_at"),
            last_telegram_error=payload.get("last_telegram_error"),
            extra=extra,
        )


class StateStore:
    def __init__(self, path: str | Path):
        self.path = Path(path)

    def load(self) -> BotState:
        if not self.path.exists():
            return BotState()
        with self.path.open("r", encoding="utf-8") as handle:
            return BotState.from_dict(json.load(handle))

    def save(self, state: BotState) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("w", encoding="utf-8") as handle:
            json.dump(state.to_dict(), handle, indent=2, sort_keys=True)
            handle.write("\n")
