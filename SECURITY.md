# Security Policy

## Reporting a vulnerability

If you find a security issue in `infra-bot`, please open a **private** GitHub security advisory on the repository (or contact the maintainer) rather than filing a public issue with exploit details.

Please include:

- affected version / commit
- description of the issue
- steps to reproduce
- impact assessment if known

## Scope

This project is a host agent that can run `apt` upgrades and scheduled reboots as root. Misconfiguration (over-broad Telegram/Slack allowlists, world-readable config with tokens, shared bot tokens with untrusted parties) is out of scope for “code bugs” but still dangerous in production.

## Secrets

- Never commit `/etc/infra-bot/config.yaml`, bot tokens, or GitHub PATs.
- Rotate any credential that may have been exposed.
