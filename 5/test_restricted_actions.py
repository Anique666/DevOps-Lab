"""Run restricted actions inside a container protected by AppArmor."""

import sys
import time
from pathlib import Path

import docker

PROFILE = "my-apparmor-profile"
IMAGE = "flask-apparmor"
CONTAINER = "flask-apparmor-test"
BASE_DIR = Path(__file__).resolve().parent

READ_PROFILE = "print(open('/proc/self/attr/current').read().strip())"
READ_PASSWD = "print(open('/etc/passwd').read())"
CHECK_HTTP = (
    "import urllib.request; "
    "print(urllib.request.urlopen('http://127.0.0.1:5000/').read().decode())"
)


def run_command(container, label, command):
    """Return (exit_code, output). exit_code is None if the runtime refused."""
    try:
        exit_code, output = container.exec_run(command)
        text = output.decode(errors="replace").strip()
        print(f"{label}: exit {exit_code}, output: {text!r}")
        return exit_code, text
    except docker.errors.APIError as exc:
        print(f"{label}: blocked by the container runtime ({exc.explanation})")
        return None, ""


def main():
    client = docker.from_env()

    if client.containers.list(all=True, filters={"name": f"^{CONTAINER}$"}):
        print(f"Container '{CONTAINER}' already exists. Remove it first.", file=sys.stderr)
        return 1

    client.images.build(path=str(BASE_DIR), tag=IMAGE)

    try:
        container = client.containers.run(
            IMAGE,
            name=CONTAINER,
            ports={"5000/tcp": 5000},
            security_opt=[f"apparmor={PROFILE}"],
            detach=True,
        )
    except docker.errors.APIError as exc:
        print(f"Could not start the container: {exc}", file=sys.stderr)
        print("Load the profile first with: sudo ./install-profile.sh", file=sys.stderr)
        return 1

    try:
        time.sleep(2)
        _, effective = run_command(
            container, "Effective isolation label", ["python", "-c", READ_PROFILE]
        )
        enforced = PROFILE in effective

        if not enforced:
            print(
                f"\nWARNING: '{PROFILE}' is not the effective label. "
                "The checks below show the host's default container policy, "
                "not the AppArmor profile.\n"
            )

        cat_code, _ = run_command(
            container, "Execute cat /etc/passwd", ["cat", "/etc/passwd"]
        )
        passwd_code, _ = run_command(
            container,
            "Read /etc/passwd through Python",
            ["python", "-c", READ_PASSWD],
        )
        bash_code, _ = run_command(
            container, "Execute /bin/bash -c id", ["/bin/bash", "-c", "id"]
        )
        http_code, http_body = run_command(
            container, "Flask still serves requests", ["python", "-c", CHECK_HTTP]
        )

        if not enforced:
            return 1

        checks = {
            "profile enforced": enforced,
            "cat blocked": cat_code is None or cat_code != 0,
            "read /etc/passwd blocked": passwd_code != 0,
            "bash blocked": bash_code is None or bash_code != 0,
            "Flask works": http_code == 0
            and "secure Flask application" in http_body,
        }
        print()
        for name, passed in checks.items():
            print(f"{'PASS' if passed else 'FAIL'}: {name}")
        return 0 if all(checks.values()) else 1
    finally:
        container.stop()
        container.remove()
        print("Container stopped and removed.")


if __name__ == "__main__":
    sys.exit(main())
