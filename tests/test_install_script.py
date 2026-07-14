from pathlib import Path
import shlex
import subprocess


SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def run_install_shell(script_body: str) -> subprocess.CompletedProcess[str]:
    script = SCRIPTS / "install.sh"
    command = f"source {shlex.quote(str(script))}\n{script_body}"
    return subprocess.run(["bash", "-lc", command], capture_output=True, text=True, check=False)


def test_install_script_has_valid_bash_syntax() -> None:
    subprocess.run(["bash", "-n", str(SCRIPTS / "install.sh")], check=True)
    subprocess.run(["bash", "-n", str(SCRIPTS / "get-infra-bot.sh")], check=True)


def test_parse_args_enables_update_mode() -> None:
    result = run_install_shell(
        """
parse_args --update --repo-slug example/infra-bot --ref main
printf 'UPDATE_MODE=%s KEEP_CONFIG=%s NON_INTERACTIVE=%s REPO=%s REF=%s\\n' \
  "${UPDATE_MODE}" "${KEEP_CONFIG}" "${NON_INTERACTIVE}" "${DEFAULT_REPO_SLUG}" "${DEFAULT_REPO_REF}"
"""
    )
    assert result.returncode == 0, result.stderr
    assert "UPDATE_MODE=1" in result.stdout
    assert "KEEP_CONFIG=1" in result.stdout
    assert "NON_INTERACTIVE=1" in result.stdout
    assert "REPO=example/infra-bot" in result.stdout
    assert "REF=main" in result.stdout


def test_validate_required_inputs_accepts_telegram_only_mode() -> None:
    result = run_install_shell(
        """
SERVER_NAME=web-01
MESSAGING_MODE=telegram
TELEGRAM_BOT_TOKEN=token
ALLOWED_CHAT_IDS=1,2
POLL_TIMEOUT_SECONDS=30
STAGGER_MINUTES=0
USE_DIST_UPGRADE=true
AUTOREMOVE=true
REBOOT_GRACE_MINUTES=5
validate_required_inputs
"""
    )

    assert result.returncode == 0, result.stderr


def test_validate_required_inputs_accepts_slack_only_mode() -> None:
    result = run_install_shell(
        """
SERVER_NAME=web-01
MESSAGING_MODE=slack
SLACK_BOT_TOKEN=xoxb-test
SLACK_APP_TOKEN=xapp-test
SLACK_ALLOWED_USER_IDS=U1,U2
SLACK_CHANNEL_IDS=C1
SLACK_COMMAND_NAME=/infra-bot
STAGGER_MINUTES=0
USE_DIST_UPGRADE=true
AUTOREMOVE=true
REBOOT_GRACE_MINUTES=5
validate_required_inputs
"""
    )

    assert result.returncode == 0, result.stderr


def test_validate_required_inputs_accepts_both_mode() -> None:
    result = run_install_shell(
        """
SERVER_NAME=web-01
MESSAGING_MODE=both
TELEGRAM_BOT_TOKEN=token
ALLOWED_CHAT_IDS=1
POLL_TIMEOUT_SECONDS=30
SLACK_BOT_TOKEN=xoxb-test
SLACK_APP_TOKEN=xapp-test
SLACK_ALLOWED_USER_IDS=U1
SLACK_CHANNEL_IDS=C1
SLACK_COMMAND_NAME=/infra-bot
STAGGER_MINUTES=0
USE_DIST_UPGRADE=true
AUTOREMOVE=true
REBOOT_GRACE_MINUTES=5
validate_required_inputs
"""
    )

    assert result.returncode == 0, result.stderr


def test_validate_required_inputs_rejects_missing_slack_credentials() -> None:
    result = run_install_shell(
        """
SERVER_NAME=web-01
MESSAGING_MODE=slack
SLACK_ALLOWED_USER_IDS=U1
SLACK_CHANNEL_IDS=C1
SLACK_COMMAND_NAME=/infra-bot
STAGGER_MINUTES=0
USE_DIST_UPGRADE=true
AUTOREMOVE=true
REBOOT_GRACE_MINUTES=5
validate_required_inputs
"""
    )

    assert result.returncode != 0
    assert "Slack bot token is required." in result.stderr


def test_render_config_omits_unselected_provider_sections() -> None:
    result = run_install_shell(
        """
SERVER_NAME=web-01
MESSAGING_MODE=slack
SLACK_BOT_TOKEN=xoxb-test
SLACK_APP_TOKEN=xapp-test
SLACK_ALLOWED_USER_IDS=U1
SLACK_CHANNEL_IDS=C1
SLACK_COMMAND_NAME=/infra-bot
STAGGER_MINUTES=0
USE_DIST_UPGRADE=true
AUTOREMOVE=true
REBOOT_GRACE_MINUTES=5
validate_required_inputs
render_config
"""
    )

    assert result.returncode == 0, result.stderr
    assert 'mode: "slack"' in result.stdout
    assert "slack:" in result.stdout
    assert "telegram:" not in result.stdout
