from pathlib import Path
import subprocess


def test_install_script_has_valid_bash_syntax() -> None:
    script = Path(__file__).resolve().parent.parent / "scripts" / "install.sh"
    subprocess.run(["bash", "-n", str(script)], check=True)
