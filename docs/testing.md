# Testing and reproducibility

The test layers exercise different boundaries:

1. **ERT unit tests** check inventory validation, deterministic selection, process
   state transitions, concurrency bounds, cancellation/timeout races, malformed
   worker replies, exit status, private persistence and UI/Org behavior.
2. **Real SSH integration** starts two private loopback SSH endpoints and executes
   actual Org Babel blocks over TRAMP. It measures overlapping execution and
   ordered serial execution, and tests command failures, retry, timeout and cancel.
3. **Interactive recording** uses real key input in a terminal Emacs with Vertico
   and Marginalia enabled. It shows the inventory, dashboard and result views.

## Unit tests

```sh
make check
```

Compilation treats warnings as errors. Tests do not use a personal Emacs init.
Some backend unit tests explicitly permit a local fixture to isolate Babel status
handling; that private binding is never enabled in the production execution path.
The public scheduler requires explicit SSH/TRAMP destinations.

## Real SSH tests

On Debian 13 or Ubuntu 24.04:

```sh
sudo apt-get install emacs-nox openssh-client openssh-server python3 make
sudo install -d -m 755 /run/sshd
make integration
```

Run as an ordinary, unlocked local user with key-based SSH login permitted. The
fixture accepts only its generated key, binds ports 22261 and 22262 on loopback,
and verifies a generated host key. It does not use a personal `authorized_keys`
file or contact the hosts in your inventory. It stops its own SSHD processes on
exit. If interrupted externally, run `python3 tools/lab.py stop`.

The endpoints share the local kernel. Each has a separate working directory and
fixture data. A shared clock makes interval overlap/order assertions meaningful;
this is not a network latency benchmark or proof of independent failure domains.

```sh
MULTIHOST_TEST_SELECTOR=python-backend make integration
```

Filters can shorten investigation after a failure. Final validation should run
the complete suite. Logs and generated credentials stay below `.runtime/`, which
is ignored by Git and excluded from release archives.

CI runs the same checks in Ubuntu 24.04 and Debian 13 containers, as an ordinary
user, after installing distribution-provided Emacs and OpenSSH. Exact versions
and results are printed in the job logs. A CI configuration is not itself proof
that a run passed; consult the recorded job outcome.

## Record release evidence

From the repository root, with the integration prerequisites installed:

```sh
python3 tools/validate.py --output docs/validation.json
```

Leave `MULTIHOST_TEST_SELECTOR` unset for final validation. The utility runs
`make check` and then `make integration`, records their actual exit codes and ERT
summaries, and hashes the source files and logs. It writes `check.log` and
`integration.log` beside the JSON report. `--unit-only` is available for a shorter
development check; it does not establish that SSH integration passed.

The recorded 1.0.0 [validation report](validation.json) contains **77 passing unit
tests and 13 passing real-SSH integration tests**, with the Emacs version and
source hashes used for those runs.

Run validation again after changing the executable source. The recorded demo
also contains source hashes in `docs/demo-results.json`, so its relationship to
the tested release can be checked rather than inferred from the video.

## Build and verify a release archive

Review the publishable files and stage or commit them before packaging. The
packager uses `git ls-files` to select tracked/staged paths, then reads their
current working-tree contents. Untracked documentation or new source files must
therefore be staged to enter the archive. Never stage operational credentials or
real inventories. The packager rejects runtime directories, compiled caches and
symlinks, even if they were accidentally tracked.

```sh
git status --short
python3 tools/package.py --version 1.0.0
```

This creates `dist/emacs-multihost-1.0.0.tar.gz` and its `.sha256` companion. An
existing archive is not overwritten. The archive includes a `SHA256SUMS` manifest
and uses fixed timestamps; the same reviewed contents and file modes produce the
same archive. To check an extracted release:

```sh
tar -xzf dist/emacs-multihost-1.0.0.tar.gz
cd emacs-multihost-1.0.0
sha256sum -c SHA256SUMS
make check
```

Generated SSH credentials and `.runtime/` are not part of the release. The SSH
integration lab is recreated when `make integration` runs in the extracted tree.

## CyberArk

The tests do not pretend to implement CyberArk PSMP. SSH aliases and TRAMP routing
are tested; MFA, credential policies, command restrictions, recording, ticketing
and audit need acceptance tests in a real authorized deployment. The checklist
and official references are in [psmp.md](psmp.md).
