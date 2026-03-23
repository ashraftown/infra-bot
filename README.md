# infra-bot

`infra-bot` is a small Python service for Ubuntu 24.04 hosts that:

- polls Telegram for read-only bot commands
- applies weekly `apt` upgrades locally on each server
- alerts configured Telegram chats on start, success, failure, and reboot scheduling
- stores operational state in a local JSON file

## Project layout

- `infra_bot/`: application code
- `deploy/config/config.example.yaml`: example host config
- `deploy/systemd/`: service and timer units
- `scripts/install.sh`: interactive host installer
- `tests/`: unit and integration-style tests

## Install

Primary path:

```bash
sudo ./scripts/install.sh
```

The installer:

- validates the host environment
- prompts for Telegram and host-specific settings
- installs the app into `/opt/infra-bot/.venv`
- writes `/etc/infra-bot/config.yaml`
- installs and enables the `systemd` service and timer

For the three-server rollout, use stagger values:

- first host: `0`
- second host: `15`
- third host: `30`

Re-running `sudo ./scripts/install.sh` is safe. It reuses the current config as prompt defaults, refreshes the deployed source tree, reinstalls the package into the managed virtualenv, and restarts the owned services.

## Manual Install

```bash
sudo mkdir -p /opt/infra-bot/src /etc/infra-bot /var/lib/infra-bot
sudo cp -R . /opt/infra-bot/src
cd /opt/infra-bot/src
sudo python3 -m venv /opt/infra-bot/.venv
sudo /opt/infra-bot/.venv/bin/pip install /opt/infra-bot/src
```

Copy the sample config:

```bash
sudo cp deploy/config/config.example.yaml /etc/infra-bot/config.yaml
sudo chown root:infra-bot /etc/infra-bot/config.yaml
sudo chmod 640 /etc/infra-bot/config.yaml
```

Adjust:

- `server_name`
- `telegram.bot_token`
- `telegram.allowed_chat_ids`
- `update_policy.stagger_minutes`

## Systemd

Install the units:

```bash
sudo cp deploy/systemd/*.service /etc/systemd/system/
sudo cp deploy/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now infra-bot.service
sudo systemctl enable --now infra-bot-update.timer
```

Per host, adjust the timer calendar to get:

- server 1: `02:00`
- server 2: `02:15`
- server 3: `02:30`

The default unit ships with `02:00`. The installer generates the host-specific `OnCalendar` value automatically.

## Commands

```bash
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml run-bot
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml run-update
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml status
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml pending-updates
```

## Telegram commands

- `/start`
- `/status`
- `/updates`
- `/lastrun`
- `/reboot`
- `/help`

## Notes

- The same Telegram bot token can be reused across all servers.
- In this local-agent design, commands target the individual server running the bot.
- There is no central aggregation layer in this version.
- The installer prefers `setfacl` for a root-owned `0600` config while still allowing the `infra-bot` service user to read it; if ACL tools are unavailable it falls back to `0640 root:infra-bot`.
