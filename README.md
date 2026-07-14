# infra-bot

`infra-bot` is a small Python service for Ubuntu 24.04 hosts that:

- polls Telegram and/or Slack for read-only bot commands
- applies weekly `apt` upgrades locally on each server
- alerts configured Telegram chats and/or Slack channels on start, success, failure, and reboot scheduling
- stores operational state in a local JSON file

Host secrets (bot tokens, chat IDs, channel IDs) live only in `/etc/infra-bot/config.yaml` on each machine. They are never required in the git repository.

## Project layout

- `infra_bot/`: application code
- `deploy/config/config.example.yaml`: example host config (placeholders only)
- `deploy/systemd/`: service and timer units
- `scripts/install.sh`: interactive host installer
- `scripts/get-infra-bot.sh`: remote install / self-update entrypoint
- `tests/`: unit and integration-style tests

## Install

### One-line bootstrap (recommended)

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash
```

With options:

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- --server-name web-01 --stagger-minutes 0
```

Update an existing install from the same URL:

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- update
# or, after first install:
sudo infra-bot-update
```

The bootstrap script downloads this repo from GitHub (public HTTPS), then runs the interactive installer (or `--update`).

### First install (from a git checkout)

```bash
git clone https://github.com/ashraftown/infra-bot.git
cd infra-bot
sudo ./scripts/install.sh
```

The installer:

- validates the host environment
- prompts for messaging and host-specific settings
- installs the app into `/opt/infra-bot/.venv`
- writes `/etc/infra-bot/config.yaml`
- writes `/etc/infra-bot/install.conf` (source repo metadata for self-update)
- installs `sudo infra-bot-update` for day-2 upgrades
- installs and enables the `systemd` service and timer

### Update an already-installed host

```bash
sudo infra-bot-update
```

That command:

1. downloads the configured ref into a temporary directory (for example `/tmp/infra-bot-src.*`)
2. reinstalls the package into `/opt/infra-bot/.venv` and `/opt/infra-bot/src`
3. refreshes systemd units
4. restarts services
5. **keeps** `/etc/infra-bot/config.yaml` unchanged
6. deletes the temporary download when finished

You do **not** need a permanent `~/infra-bot` checkout on each host. After `sudo infra-bot-update` works once, you can remove any local clone if you want.

Useful variants:

```bash
sudo infra-bot-update --ref main
sudo infra-bot-update --local          # use a local checkout next to the script
sudo ./scripts/install.sh --update     # reinstall from the current checkout only
```

Roll several hosts:

```bash
for h in host-a host-b host-c; do
  ssh "$h" 'sudo infra-bot-update'
done
```

### Messaging modes

- `telegram`: Telegram commands and Telegram notifications
- `slack`: Slack slash-command support and Slack notifications
- `both`: Telegram and Slack together

For multi-host rollouts, stagger weekly updates (minutes after Sunday 02:00 UTC base):

- first host: `0`
- second host: `15`
- third host: `30`

Re-running `sudo ./scripts/install.sh` (without `--update`) is still safe for interactive reconfiguration. It reuses the current config as prompt defaults, refreshes the deployed source tree, reinstalls the package into the managed virtualenv, and restarts the owned services.

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
- `messaging.mode`
- `telegram.bot_token` and `telegram.allowed_chat_ids` when Telegram is enabled
- `slack.bot_token`, `slack.app_token`, `slack.allowed_user_ids`, and `slack.notification_channel_ids` when Slack is enabled
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

Per host, adjust the timer calendar (or use the installer, which sets `OnCalendar` from stagger minutes). The default unit ships with `02:00` Sunday.

## CLI

```bash
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml run-bot
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml run-update
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml status
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml pending-updates
```

## Bot commands

- `/start`
- `/status`
- `/updates`
- `/lastrun`
- `/reboot`
- `/help`

Telegram uses those commands directly.

Slack uses a single slash command, default `/infra-bot`, with the command name as the first argument:

- `/infra-bot status`
- `/infra-bot updates`
- `/infra-bot lastrun`
- `/infra-bot reboot`
- `/infra-bot help`

## Slack setup

For Slack mode, create and install a Slack app with:

- a bot token (`xoxb-...`)
- an app-level token (`xapp-...`)
- Socket Mode enabled
- a slash command, default `/infra-bot`
- permissions sufficient to post messages and receive slash commands

The installer prompts for:

- `slack.bot_token`
- `slack.app_token`
- `slack.allowed_user_ids`
- `slack.notification_channel_ids`
- `slack.command_name`

## Security notes

- Keep real tokens and chat/channel IDs only in `/etc/infra-bot/config.yaml` on hosts (mode `0600`/`0640`, not world-readable).
- Telegram and Slack commands are allowlisted (`allowed_chat_ids` / `allowed_user_ids`).
- Weekly package updates run as root via systemd; the messaging bot runs as the unprivileged `infra-bot` user.
- Bot commands are read-only operational views; reboots are not triggered from chat (`/reboot` is informational only).
- Self-update uses the public HTTPS GitHub URL written to `/etc/infra-bot/install.conf`. GitHub tokens are **not** stored on disk.
- Do not commit host configs or bot tokens.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

## Notes

- The same Telegram bot token can be reused across all servers.
- Slack support uses Socket Mode, so no public inbound HTTP endpoint is required per host.
- In this local-agent design, commands target the individual server running the bot.
- There is no central aggregation layer in this version.
- The installer prefers `setfacl` for a root-owned `0600` config while still allowing the `infra-bot` service user to read it; if ACL tools are unavailable it falls back to `0640 root:infra-bot`.
