#!/usr/bin/env python3
"""Private, unprivileged two-host SSH fixture for integration tests.

The endpoints share the local kernel; they are not separate machines and do not
simulate a CyberArk deployment.  Only generated keys are accepted.  No personal
SSH configuration or authorized_keys file is read or modified.

StrictModes is disabled only in these generated loopback server configurations:
otherwise OpenSSH rejects private fixture keys below a shared ancestor such as
/tmp or a CI workspace.  The fixture directory and authorization file are
explicitly checked as user-owned 0700 and 0600, respectively.  Client host-key
verification remains strict.  Production SSH/TRAMP configuration is unaffected.
"""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
LAB = ROOT / ".runtime" / "lab"
STATE = LAB / "state.json"
ROLES = (("web", 22261), ("db", 22262))


def executable(name):
    """Find a real executable even if the fixture wrapper is already on PATH."""
    search = os.pathsep.join(part for part in os.get_exec_path()
                             if Path(part).resolve() != (LAB / "bin").resolve())
    return shutil.which(name, path=search)


def private_write(path, content, mode=0o600):
    """Write generated private data without relying on the caller's umask."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as output:
        output.write(content)
    path.chmod(mode)


def own_process(row):
    """Do not signal a reused PID belonging to a different program."""
    try:
        command = Path(f'/proc/{row["pid"]}/cmdline').read_bytes()
    except FileNotFoundError:
        return False
    return b"sshd" in command and os.fsencode(row["config"]) in command


def stop():
    if not STATE.exists():
        return
    for row in json.loads(STATE.read_text()):
        if own_process(row):
            try:
                os.kill(row["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
    STATE.unlink(missing_ok=True)


def start():
    if STATE.exists():
        rows = json.loads(STATE.read_text())
        if all(own_process(row) for row in rows):
            print(f"SSH lab already running: {LAB}")
            return
        stop()
    sshd = executable("sshd") or "/usr/sbin/sshd"
    for program in (sshd, "ssh", "ssh-keygen"):
        if not executable(program):
            raise RuntimeError(f"Missing {program}; install OpenSSH client/server first")
    for _, port in ROLES:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
    LAB.mkdir(parents=True, exist_ok=True, mode=0o700)
    LAB.chmod(0o700)
    user = subprocess.check_output(["id", "-un"], text=True).strip()
    for key in ("host_key", "client_key"):
        target = LAB / key
        if not target.exists():
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(target)], check=True)
        target.chmod(0o600)
    private_write(LAB / "authorized_keys", (LAB / "client_key.pub").read_text())
    for path, mode in ((LAB, 0o700), (LAB / "authorized_keys", 0o600)):
        attributes = path.stat()
        if attributes.st_uid != os.getuid() or stat.S_IMODE(attributes.st_mode) != mode:
            raise RuntimeError(f"Unsafe fixture ownership or permissions: {path}")
    public = (LAB / "host_key.pub").read_text().split()
    private_write(LAB / "known_hosts", "".join(
        f"[127.0.0.1]:{port} {public[0]} {public[1]}\n" for _, port in ROLES))
    configs = []
    for role, port in ROLES:
        directory = LAB / role
        directory.mkdir(exist_ok=True, mode=0o700)
        private_write(directory / "status.txt", f"role={role}\nservice=active\n")
        private_write(directory / "retry-state", "fail\n")
        config = LAB / f"{role}-sshd_config"
        private_write(config, f"""Port {port}
ListenAddress 127.0.0.1
HostKey {LAB}/host_key
PidFile {LAB}/{role}.pid
AuthorizedKeysFile {LAB}/authorized_keys
# Private fixture keys can live under /tmp; ownership/modes checked by lab.py.
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers {user}
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
LogLevel VERBOSE
Subsystem sftp internal-sftp
""")
        subprocess.run([sshd, "-t", "-f", str(config)], check=True)
        configs.append((role, port, config))
    private_write(LAB / "ssh_config", "\n".join(
        f"Host mh-lab-{role}\n  HostName 127.0.0.1\n  Port {port}\n"
        for role, port in ROLES) + f"""
Host *
  User {user}
  IdentityFile {LAB}/client_key
  IdentitiesOnly yes
  UserKnownHostsFile {LAB}/known_hosts
  GlobalKnownHostsFile /dev/null
  StrictHostKeyChecking yes
  BatchMode yes
  ControlMaster no
  ConnectTimeout 5
  LogLevel ERROR
""")
    bindir = LAB / "bin"
    bindir.mkdir(exist_ok=True, mode=0o700)
    for program in ("ssh", "scp"):
        real_program = executable(program)
        if real_program:
            private_write(bindir / program,
                          f"#!/bin/sh\nexec {shlex.quote(real_program)} -F {shlex.quote(str(LAB / 'ssh_config'))} \"$@\"\n",
                          0o700)
    private_write(LAB / "worker-init.el", """;;; Generated integration-only TRAMP configuration.
(setq user-emacs-directory
      (expand-file-name "emacs/" (file-name-directory load-file-name))
      tramp-persistency-file-name nil)
(make-directory user-emacs-directory t)
(require 'tramp)
(require 'tramp-sh)
(setq tramp-use-connection-share nil)
""")
    rows = []
    try:
        for role, port, config in configs:
            with (LAB / f"{role}-sshd.log").open("w") as log:
                process = subprocess.Popen([sshd, "-D", "-e", "-f", str(config)], stdout=log, stderr=log,
                                           start_new_session=True)
            rows.append({"role": role, "port": port, "pid": process.pid, "config": str(config)})
            private_write(STATE, json.dumps(rows, indent=2) + "\n")
        for role, _ in ROLES:
            deadline = time.monotonic() + 8
            while True:
                check = subprocess.run([executable("ssh"), "-F", str(LAB / "ssh_config"), f"mh-lab-{role}",
                                        "cat " + shlex.quote(str(LAB / role / "status.txt"))],
                                       capture_output=True, text=True, timeout=7)
                if check.returncode == 0:
                    break
                if time.monotonic() >= deadline:
                    server_log = (LAB / f"{role}-sshd.log").read_text(errors="replace")[-4000:]
                    raise RuntimeError(f"SSH lab {role} failed: {check.stderr.strip()}\n"
                                       f"Server log (last 4000 characters):\n{server_log}")
                time.sleep(0.1)
            if f"role={role}\n" not in check.stdout:
                raise RuntimeError(f"Unexpected response from {role}")
        print(f"SSH lab ready: web=127.0.0.1:22261, db=127.0.0.1:22262 ({LAB})")
    except BaseException:
        stop()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "stop", "status"))
    action = parser.parse_args().action
    if action == "start":
        start()
    elif action == "stop":
        stop()
    else:
        print(STATE.read_text() if STATE.exists() else "SSH lab stopped")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
