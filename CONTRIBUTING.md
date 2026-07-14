# Contributing

Thanks for helping improve `infra-bot`.

## Development setup

```bash
git clone https://github.com/ashraftown/infra-bot.git
cd infra-bot
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
pip install pytest
pytest -q
```

Target platform is **Ubuntu 24.04**. The installer and systemd units assume `apt` and `systemctl`.

## Project conventions

- Keep host secrets out of the repo. Use placeholders in examples and tests only.
- Prefer small, focused pull requests with tests for behavior changes.
- Installer changes should keep `sudo ./scripts/install.sh --update` non-interactive and config-preserving.
- Self-update (`sudo infra-bot-update`) should work against the public HTTPS GitHub URL without a stored token.

## Pull requests

1. Fork and branch from `main`.
2. Add or update tests when changing Python behavior.
3. Run `pytest -q` (and `bash -n scripts/*.sh` for shell changes).
4. Open a PR with a short summary of *what* changed and *why*.

## Reporting security issues

Do not open a public issue for vulnerabilities. See [SECURITY.md](SECURITY.md).

## Code of conduct

Be respectful. Assume good intent. No harassment or personal attacks.
