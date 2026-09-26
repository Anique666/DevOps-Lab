"""Build the image and start a container with the AppArmor profile."""

import sys
import time
from pathlib import Path

import docker

PROFILE = "my-apparmor-profile"
IMAGE = "flask-apparmor"
CONTAINER = "flask-apparmor-check"
BASE_DIR = Path(__file__).resolve().parent

CHECK_HTTP = (
    "import urllib.request; "
    "print(urllib.request.urlopen('http://127.0.0.1:5000/').read().decode())"
)
READ_PROFILE = "print(open('/proc/self/attr/current').read().strip())"


def main():
    client = docker.from_env()

    if client.containers.list(all=True, filters={"name": f"^{CONTAINER}$"}):
        print(f"Container '{CONTAINER}' already exists. Remove it first.", file=sys.stderr)
        return 1

    print("Building image...")
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
        info = client.api.inspect_container(container.id)
        print("SecurityOpt:", info["HostConfig"]["SecurityOpt"])

        # SecurityOpt only records the request. The kernel's effective label is
        # in /proc/self/attr/current.
        _, output = container.exec_run(["python", "-c", READ_PROFILE])
        effective = output.decode().strip()
        print("Effective profile:", effective)

        # Give Flask time to bind the port.
        body = None
        for _ in range(20):
            exit_code, output = container.exec_run(["python", "-c", CHECK_HTTP])
            if exit_code == 0:
                body = output.decode().strip()
                break
            time.sleep(0.5)

        print("HTTP response:", body)

        if PROFILE not in effective:
            print(
                "ERROR: Docker recorded the option, but the kernel is not "
                f"enforcing '{PROFILE}'. Effective label: {effective}",
                file=sys.stderr,
            )
            print(
                "This host probably uses SELinux instead of AppArmor. "
                "No AppArmor restriction was applied.",
                file=sys.stderr,
            )
            return 1

        if body is None:
            print("ERROR: The container did not answer on port 5000.", file=sys.stderr)
            return 1

        print("AppArmor profile is enforcing and the Flask app responds.")
        return 0
    finally:
        container.stop()
        container.remove()
        print(f"Container {container.short_id} stopped and removed.")


if __name__ == "__main__":
    sys.exit(main())
