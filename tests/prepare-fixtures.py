#!/usr/bin/env python3
"""Copy installer scripts into a private filesystem and create local archives."""
import io
from pathlib import Path
import sys
import tarfile

repo, root = map(Path, sys.argv[1:])
scripts = [repo / script for script in ("tailscale.sh", "uninstall.sh", "override.conf")]
scripts.extend((repo / "lib").glob("*.sh"))
for script in scripts:
    source = script.read_text()
    # Fixed production destinations only. The production scripts have no test mode.
    for path in ("/etc", "/var", "/run", "/opt", "/home"):
        source = source.replace(path, str(root / path.lstrip("/")))
    source = source.replace("[[ $EUID -eq 0 ]]", "[[ $(id -u) -eq 0 ]]")
    target = root / script.relative_to(repo)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(source)

fixtures = root / "fixtures"
fixtures.mkdir(exist_ok=True)
for version in ("1.2.3", "1.2.4"):
    for arch in ("arm64", "amd64"):
        directory = f"tailscale_{version}_{arch}"
        with tarfile.open(fixtures / f"{directory}.tgz", "w:gz") as archive:
            files = {
                "tailscale": f"#!/bin/sh\n# tailscale-{version}-{arch}\nprintf '%s\\n' '{version}'\n",
                "tailscaled": f"#!/bin/sh\n# tailscaled-{version}-{arch}\nprintf '%s\\n' '{version}'\n",
                "systemd/tailscaled.service": "[Unit]\nDescription=Tailscale\n[Service]\nEnvironmentFile=/etc/default/tailscaled\nExecStart=/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=${PORT} $FLAGS\nExecStopPost=/usr/bin/tailscale down\n[Install]\nWantedBy=multi-user.target\n",
                "systemd/tailscaled.defaults": 'PORT="41641"\nFLAGS=""\n',
            }
            if version == "1.2.4" and (root / "omit-binary").exists():
                del files["tailscaled"]
            if version == "1.2.4" and (root / "wrong-version").exists():
                files["tailscaled"] = "#!/bin/sh\nprintf '%s\\n' '9.9.9'\n"
            for name, content in files.items():
                data = content.encode()
                member = tarfile.TarInfo(directory + "/" + name)
                member.size = len(data)
                member.mode = 0o755 if "/" not in name else 0o644
                archive.addfile(member, io.BytesIO(data))
