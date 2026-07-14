# infra-bot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Python](https://img.shields.io/badge/Python-3.9%2B-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Telegram](https://img.shields.io/badge/Telegram-ready-26A5E4?logo=telegram&logoColor=white)](https://telegram.org/)
[![Slack](https://img.shields.io/badge/Slack-ready-4A154B?logo=slack&logoColor=white)](https://slack.com/)

**Local Ubuntu update agent** with Telegram and Slack notifications.

Each host runs its own agent: weekly `apt` upgrades, optional scheduled reboots, and chat commands for status — no central control plane required.

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Weekly upgrades** | `apt-get update` / `upgrade` / optional `dist-upgrade` + `autoremove` |
| **Chat alerts** | Start, success (with package versions), failure, reboot scheduling |
| **Messaging** | Telegram, Slack, or both |
| **Bot commands** | `/status`, `/updates`, `/lastrun`, and more (read-only) |
| **Self-update** | `sudo infra-bot-update` — no permanent git checkout on the host |
| **Secrets on host** | Tokens and chat IDs only in `/etc/infra-bot/config.yaml` |

---

## Quick start

### Install

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash
```

With options:

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh \
  | sudo bash -s -- --server-name web-01 --stagger-minutes 0
```

### Update

```bash
sudo infra-bot-update
```

Or via the same bootstrap URL:

```bash
curl -fsSL https://corewaze.com/infra-bot/install.sh | sudo bash -s -- update
```

### Roll several hosts

```bash
for h in host-a host-b host-c; do
  ssh "$h" 'sudo infra-bot-update'
done
```

> **Tip:** After the first successful update you can delete any `~/infra-bot` clone. Day-2 is just `sudo infra-bot-update`.

---

## What the installer does

1. Validates Ubuntu / installs prerequisites  
2. Prompts for messaging settings (or reuses existing config)  
3. Installs into `/opt/infra-bot/.venv`  
4. Writes `/etc/infra-bot/config.yaml` and `/etc/infra-bot/install.conf`  
5. Installs `sudo infra-bot-update`  
6. Enables `infra-bot.service` + weekly `infra-bot-update.timer`  

---

## Messaging modes

| Mode | Behavior |
|------|----------|
| `telegram` | Telegram commands + notifications |
| `slack` | Slack slash commands + notifications |
| `both` | Telegram and Slack together |

### Stagger (multi-host)

Base schedule is **Sunday 02:00**. Set stagger minutes per host:

| Host order | `stagger_minutes` | Runs at |
|------------|-------------------|---------|
| 1st | `0` | 02:00 |
| 2nd | `15` | 02:15 |
| 3rd | `30` | 02:30 |

---

## Bot commands

### Telegram

| Command | Description |
|---------|-------------|
| `/start` | Identity + help |
| `/status` | Health summary |
| `/updates` | Pending packages (with versions) |
| `/lastrun` | Last maintenance run |
| `/reboot` | Info only — reboots are automated |
| `/help` | Command list |

### Slack

Single slash command (default `/infra-bot`), first argument is the action:

```text
/infra-bot status
/infra-bot updates
/infra-bot lastrun
/infra-bot reboot
/infra-bot help
```

### Slack app requirements

- Bot token (`xoxb-…`)
- App-level token (`xapp-…`)
- **Socket Mode** enabled (no public inbound HTTP per host)
- Slash command (default `/infra-bot`)
- Permissions to post messages and receive slash commands

---

## CLI

```bash
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml run-bot
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml run-update
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml status
/opt/infra-bot/.venv/bin/infra-bot --config /etc/infra-bot/config.yaml pending-updates
```

---

## Project layout

```text
infra_bot/                 # Application code
deploy/config/             # Example host config (placeholders only)
deploy/systemd/            # Service and timer units
scripts/install.sh         # Interactive host installer
scripts/bootstrap-install.sh   # curl | bash entrypoint (served at corewaze.com)
scripts/get-infra-bot.sh   # Self-update helper used by infra-bot-update
tests/                     # Unit tests
```

---

## Security

- Keep tokens and chat/channel IDs **only** in `/etc/infra-bot/config.yaml` on each host (`0600` / `0640`, not world-readable).
- Telegram / Slack access is **allowlisted** (`allowed_chat_ids` / `allowed_user_ids`).
- Messaging bot runs as unprivileged user `infra-bot`; weekly package updates run as **root** via systemd.
- Chat commands are **read-only**; `/reboot` does not reboot the host.
- Self-update uses public HTTPS GitHub; **no GitHub tokens** are stored on disk.
- Never commit host configs or real bot tokens.

See [SECURITY.md](SECURITY.md) to report vulnerabilities.

---

## Advanced install

<details>
<summary><strong>Install from a git checkout</strong></summary>

```bash
git clone https://github.com/ashraftown/infra-bot.git
cd infra-bot
sudo ./scripts/install.sh
```

Re-running without `--update` is safe for interactive reconfiguration (reuses current config as defaults).

</details>

<details>
<summary><strong>Update options</strong></summary>

```bash
sudo infra-bot-update --ref main
sudo infra-bot-update --local          # use a local checkout next to the script
sudo ./scripts/install.sh --update     # reinstall from the current checkout only
```

`sudo infra-bot-update` will:

1. Download the configured ref into a temp directory  
2. Reinstall into `/opt/infra-bot/.venv` and `/opt/infra-bot/src`  
3. Refresh systemd units and restart services  
4. **Keep** `/etc/infra-bot/config.yaml` unchanged  
5. Delete the temp download when finished  

</details>

<details>
<summary><strong>Manual install</strong></summary>

```bash
sudo mkdir -p /opt/infra-bot/src /etc/infra-bot /var/lib/infra-bot
sudo cp -R . /opt/infra-bot/src
cd /opt/infra-bot/src
sudo python3 -m venv /opt/infra-bot/.venv
sudo /opt/infra-bot/.venv/bin/pip install /opt/infra-bot/src

sudo cp deploy/config/config.example.yaml /etc/infra-bot/config.yaml
sudo chown root:infra-bot /etc/infra-bot/config.yaml
sudo chmod 640 /etc/infra-bot/config.yaml
```

Edit at least:

- `server_name`
- `messaging.mode`
- Telegram and/or Slack credentials
- `update_policy.stagger_minutes`

Then install units:

```bash
sudo cp deploy/systemd/*.service /etc/systemd/system/
sudo cp deploy/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now infra-bot.service
sudo systemctl enable --now infra-bot-update.timer
```

The default timer is Sunday `02:00`. Prefer the installer, which sets `OnCalendar` from stagger minutes.

</details>

<details>
<summary><strong>Notes</strong></summary>

- The same Telegram bot token can be reused on every server.
- Slack uses Socket Mode — no public webhook URL per host.
- Commands always target the **individual** host running the bot (no central aggregation).
- Config permissions: installer prefers `setfacl` for root-owned `0600` while allowing the `infra-bot` user to read; otherwise `0640 root:infra-bot`.

</details>

---

## License & contributing

| Resource | Link |
|----------|------|
| **License** | [MIT](LICENSE) |
| **Contributing** | [CONTRIBUTING.md](CONTRIBUTING.md) |
| **Security** | [SECURITY.md](SECURITY.md) |
