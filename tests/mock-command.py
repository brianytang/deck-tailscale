#!/usr/bin/env python3
"""Offline command doubles for the non-root installer integration tests."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["TEST_ROOT"])
events = Path(os.environ["TEST_EVENTS"])


def log(message):
    with events.open("a") as stream:
        stream.write(message + "\n")


def guarded_arguments(arguments):
    for argument in arguments:
        if argument.startswith("/"):
            path = Path(argument).absolute()
            if path != root and root not in path.parents:
                raise SystemExit("refusing operation outside test fixture: " + argument)


log(name + " " + " ".join(args))
if name == "id":
    print("0" if "-u" in args else "uid=0(root) gid=0(root)")
elif name == "uname":
    print(os.environ.get("TEST_ARCH", "aarch64"))
elif name == "stat":
    format_arg = args[args.index("-c") + 1] if "-c" in args else ""
    if format_arg in ("%u", "%U", "%u:%g"):
        guarded_arguments([arg for arg in args if arg.startswith("/")])
        owner = os.environ.get("TEST_OWNER", "0")
        unsafe_path = os.environ.get("TEST_UNSAFE_OWNER_PATH", "")
        if unsafe_path and any(arg.endswith(unsafe_path) for arg in args):
            owner = "1000"
        print(owner + ":0" if format_arg == "%u:%g" else owner)
    else:
        raise SystemExit(subprocess.call(["/usr/bin/stat", *args]))
elif name == "chown":
    guarded_arguments([arg for arg in args[1:] if arg.startswith("/")])
elif name == "curl":
    url = next((arg for arg in args if arg.startswith("https://")), "")
    fixture = Path(os.environ["TEST_FIXTURES"])
    version = os.environ.get("TEST_VERSION", "1.2.3")
    arch = "arm64" if os.environ.get("TEST_ARCH", "aarch64") in ("aarch64", "arm64") else "amd64"
    tarball = f"tailscale_{version}_{arch}.tgz"
    if os.environ.get("TEST_DOWNLOAD_FAILURE") == "1" and "mode=json" not in url:
        raise SystemExit(22)
    if "mode=json" in url:
        if os.environ.get("TEST_BAD_METADATA") == "1":
            data = json.dumps({"Tarballs": {"arm64": "../unexpected.tgz", "amd64": "../unexpected.tgz"}}).encode()
        else:
            data = json.dumps({"Tarballs": {key: f"tailscale_{version}_{key}.tgz" for key in ("arm64", "amd64")}}).encode()
    elif url.endswith(".sha256"):
        data = (hashlib.sha256((fixture / tarball).read_bytes()).hexdigest() + "\n").encode()
        if os.environ.get("TEST_BAD_CHECKSUM") == "1":
            data = ("0" * 64 + "\n").encode()
        if os.environ.get("TEST_CHECKSUM_NO_NEWLINE") == "1":
            data = data.rstrip(b"\n")
    elif url.endswith(".tgz"):
        if url.rsplit("/", 1)[-1] != tarball:
            raise SystemExit("unexpected archive URL: " + url)
        data = (fixture / tarball).read_bytes()
    else:
        raise SystemExit("unexpected curl URL: " + url)
    output = None
    for option in ("-o", "--output"):
        if option in args:
            output = args[args.index(option) + 1]
    if output:
        guarded_arguments([output])
        Path(output).write_bytes(data)
    else:
        sys.stdout.buffer.write(data)
elif name == "jq":
    # Keep the harness independent of a host jq installation.
    source = next((arg for arg in reversed(args) if arg.startswith("/") and Path(arg).is_file()), None)
    metadata = json.loads(Path(source).read_text()) if source else json.load(sys.stdin)
    query = next((arg for arg in args if arg.startswith(".")), "")
    if query == ".Tarballs[$arch] | strings" and "--arg" in args:
        position = args.index("--arg")
        if args[position + 1] != "arch":
            raise SystemExit("unsupported jq variable")
        arch = args[position + 2]
    elif query.startswith(".Tarballs."):
        arch = query.split(".")[2]
    else:
        raise SystemExit("unsupported jq test query: " + query)
    value = metadata.get("Tarballs", {}).get(arch)
    if not isinstance(value, str):
        raise SystemExit(4)
    print(value)
elif name == "systemctl":
    operation = next((arg for arg in args if not arg.startswith("-")), "")
    if operation == "show":
        print("loaded" if (root / "etc/systemd/system/tailscaled.service").exists() or os.environ.get("TEST_VENDOR_UNIT") == "1" else "not-found")
        raise SystemExit(0)
    if operation not in ("is-active", "is-enabled", "start", "restart", "stop", "enable", "disable", "daemon-reload"):
        raise SystemExit("unsupported systemctl test operation: " + operation)
    marker = root / ("service-active" if operation in ("is-active", "start", "restart", "stop") else "service-enabled")
    if operation in ("is-active", "is-enabled"):
        raise SystemExit(0 if marker.exists() else 1)
    failure_marker = root / ("failure-used-" + operation)
    if os.environ.get("TEST_SERVICE_FAILURE") == operation and not failure_marker.exists():
        failure_marker.touch()
        raise SystemExit(1)
    if operation in ("start", "restart", "enable"):
        marker.touch()
        if operation == "enable":
            wanted = root / "etc/systemd/system/multi-user.target.wants/tailscaled.service"
            wanted.parent.mkdir(parents=True, exist_ok=True)
            wanted.unlink(missing_ok=True)
            wanted.symlink_to("../tailscaled.service")
    elif operation in ("stop", "disable"):
        marker.unlink(missing_ok=True)
        if operation == "disable":
            (root / "etc/systemd/system/multi-user.target.wants/tailscaled.service").unlink(missing_ok=True)
elif name == "systemd-sysext":
    pass
elif name == "install":
    cleaned = []
    skip = False
    for arg in args:
        if skip:
            skip = False
            continue
        if arg in ("-o", "--owner", "-g", "--group"):
            skip = True
        else:
            cleaned.append(arg)
    guarded_arguments(cleaned)
    raise SystemExit(subprocess.call(["/usr/bin/install", *cleaned]))
elif name == "sha256sum":
    raise SystemExit(subprocess.call(["/usr/bin/sha256sum", *args]))
elif name in ("rm", "mkdir", "cp", "mv", "ln", "chmod"):
    guarded_arguments(args)
    if name == "rm" and any(arg.endswith("/multi-user.target.wants/tailscaled.service") for arg in args):
        (root / "service-enabled").unlink(missing_ok=True)
    raise SystemExit(subprocess.call(["/usr/bin/" + name, *args]))
else:
    raise SystemExit("unexpected mock command: " + name)
