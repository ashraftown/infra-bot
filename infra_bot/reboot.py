from __future__ import annotations

import subprocess
from pathlib import Path


def reboot_required(marker_path: str | Path = "/var/run/reboot-required") -> bool:
    return Path(marker_path).exists()


def schedule_reboot(grace_minutes: int = 5) -> None:
    subprocess.run(
        ["/usr/sbin/shutdown", "-r", f"+{grace_minutes}", "infra-bot scheduled reboot"],
        check=True,
        capture_output=True,
        text=True,
    )

