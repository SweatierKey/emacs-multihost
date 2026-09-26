#!/usr/bin/env python3
"""Prepare pinned UI dependencies and private fixtures for the PTY demo."""

from pathlib import Path, PurePosixPath
import hashlib
import json
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / ".runtime" / "demo-deps"
PACKAGES = {
    "compat": ("emacs-compat/compat", "90880f81419577e1d3f68424d2a3adf31e6d663e",
               "91f010564b497328f1cf093de7b6f253d5f348c22a17e97e6cc1186b80a0de77"),
    "vertico": ("minad/vertico", "a9998a777f1d92348f84d091bb15b87df933a7a2",
                "c163528d6a62e340e1ab11c84b628f6e0d73fd15846fb333c5432e668e5f05a2"),
    "marginalia": ("minad/marginalia", "c5d0139012d2a84f8040219b9aee17db4e145e5c",
                   "be4bf4b1f63dcb4b977501779001a15932891c5361e7f7a04d0050aecfd76ee0"),
}


def main():
    DEPS.mkdir(parents=True, exist_ok=True)
    for name, (repository, revision, checksum) in PACKAGES.items():
        archive = DEPS / (name + ".tar.gz")
        if not archive.exists():
            url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
            with urllib.request.urlopen(url, timeout=60) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise RuntimeError(f"Checksum mismatch: {archive}; remove it and retry")
        target = DEPS / name
        target.mkdir(exist_ok=True)
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                parts = PurePosixPath(member.name).parts
                if member.name.startswith("/") or ".." in parts or not parts:
                    raise RuntimeError("Unsafe dependency archive path")
                if not member.isfile():
                    if member.isdir():
                        continue
                    raise RuntimeError("Dependency archive contains a link or special file")
                path = target.joinpath(*parts[1:])
                path.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(member) as stream, path.open("wb") as output:
                    shutil.copyfileobj(stream, output)
        print(f"Verified {name} at {revision}")
    demo = ROOT / ".runtime" / "demo"
    demo.mkdir(exist_ok=True, mode=0o700)
    demo.chmod(0o700)
    inventory = {"version": 1, "hosts": [
        {"name": role + "-01", "connection": f"/ssh:mh-lab-{role}:{ROOT}/.runtime/lab/{role}/",
         "groups": ["lab"], "description": f"Local SSH fixture: {role}"}
        for role in ("web", "db")]}
    (demo / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    (demo / "start.org").write_text("""#+title: Multihost — remote operations in Emacs

An inventory, repeatable Org runbooks, and one result per host.

In this recording:
  1. Initialize two retained SSH connections and inspect their workers.
  2. Run a parallel check; read separate, combined and grouped output.
  3. Complete remote files with host annotations in Org and its shell editor.
  4. Execute an Org runbook in selection order.
  5. Inspect an intentional failure: stderr and exit 7.

Real Emacs keys. Vertico and Marginalia are enabled.
Two loopback SSH endpoints share one kernel. No CyberArk deployment.
""")
    (demo / "runbook.org").write_text("""#+title: Operations runbook · isolated SSH lab
#+startup: showall

* Serial health check
Run db-01 first; wait for completion before starting web-01.

#+begin_src sh :hosts db-01 web-01 :concurrency 1 :renderer combined :results output :timeout 20
cat status.txt
sleep 0.5
printf 'check completed\\n'
#+end_src

* Intentional failure
The database fixture returns exit 7; the web fixture succeeds.

#+begin_src sh :hosts @lab :concurrency 2 :renderer table :results output :timeout 20
if grep -q 'role=db' status.txt; then
  printf 'database check failed\\n' >&2
  exit 7
fi
printf 'web check passed\\n'
#+end_src
""")


if __name__ == "__main__":
    main()
