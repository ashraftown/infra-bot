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
- `tests/`: unit and integration-style tests

## Install

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -e .
```

Copy the sample config:

```bash
sudo mkdir -p /etc/infra-bot /var/lib/infra-bot
sudo cp deploy/config/config.example.yaml /etc/infra-bot/config.yaml
sudo chmod 600 /etc/infra-bot/config.yaml
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

Per host, adjust the timer calendar or config stagger to get:

- server 1: `02:00`
- server 2: `02:15`
- server 3: `02:30`

Version 1 keeps timer staggering as an operational deployment choice. The example timer ships with `02:00`.

## Commands

```bash
infra-bot --config /etc/infra-bot/config.yaml run-bot
infra-bot --config /etc/infra-bot/config.yaml run-update
infra-bot --config /etc/infra-bot/config.yaml status
infra-bot --config /etc/infra-bot/config.yaml pending-updates
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

