# Emacs Multihost

**Run one operation across a deliberate set of Linux hosts. Keep the plan, the code and the results in Emacs.**

Multihost brings ordered inventories, bounded parallel execution, per-host results
repeatable Org runbooks and remote command/file completion to Emacs. It uses Org Babel and TRAMP with your existing
SSH configuration. No agent is installed on the target hosts.

[Watch the recorded workflow](https://sweatierkey.github.io/emacs-multihost/)
· [Quick start in Italian](docs/quickstart-it.md)
· [Download releases](https://github.com/SweatierKey/emacs-multihost/releases)

```org
#+name: service-health
#+begin_src sh :hosts @web :concurrency 4 :timeout 45 :renderer digest
hostname
systemctl is-active nginx
#+end_src
```

`C-c C-c` submits the run and opens a dashboard. `RET` opens one host's result;
`a` shows every result together; `d` groups identical results. Set `:concurrency 1`
for execution in the declared host order, waiting for each host to finish.

## Install

Requires **Emacs 29.1 or newer**, bundled Org 9.6 or newer, an SSH client and
Linux/POSIX targets with a shell. Python blocks also require Python on the target.
There are no mandatory third-party Emacs dependencies.

```sh
git clone https://github.com/SweatierKey/emacs-multihost.git
```

```elisp
(add-to-list 'load-path "/path/to/emacs-multihost")
(require 'multihost)
(require 'ob-multihost)
(setq multihost-inventory-file "~/ops/inventory.json")
(ob-multihost-mode 1)
```

This replaces the earlier local `ob-multihost.el`. Remove that older directory
from the relevant load-path precedence and restart Emacs before enabling this
version; do not load both implementations into one session.

## Inventory and everyday use

```json
{
  "version": 1,
  "hosts": [
    {"name": "web-01", "connection": "web-01", "groups": ["web", "prod"]},
    {"name": "web-02", "connection": "web-02", "groups": ["web", "prod"]},
    {"name": "db-01", "connection": "/ssh:psmp-db:/srv/", "groups": ["db", "prod"]}
  ]
}
```

`connection` is an SSH alias or a complete TRAMP directory. Usernames, keys,
ports and gateways remain in SSH/TRAMP configuration. Full TRAMP paths retain
their explicit hops. Inventories contain data, not executable Lisp or passwords.

Run `M-x multihost` to browse the inventory:

| Key | Action |
|---|---|
| `m` / `u` | Mark / unmark a host |
| `T` / `U` | Mark all / clear marks |
| `x` | Run a shell command on marked hosts, or the host at point |
| `C-u x` | Run the command serially in inventory order |
| `s` | Open an ordinary interactive remote shell |
| `d` | Browse remote files with Dired/TRAMP |
| `v` | Check remote identity and directory using interactive TRAMP |
| `w` | Prepare selected connections asynchronously and retain them |
| `C` | Inspect retained connections; `k` there closes one connection |
| `g` | Reload the inventory |
| `h` | Open run history |

Org selectors support `web-01 web-02`, `@web`, `web-*`, and exclusions such as
`@prod !@db`. Groups and patterns expand in inventory order; duplicates are
removed at their first occurrence. Unknown names fail before any job starts.
Without an inventory, literal SSH aliases can be used directly in `:hosts`.
See [inventory rules](docs/inventory.md).

## Runbooks

Run `M-x multihost-org-preview` inside a block to inspect targets, directories,
execution mode and unexpanded source without opening a connection or evaluating
header Lisp. Execution respects Org's `:eval` and `org-confirm-babel-evaluate`.
Ordinary blocks without `:hosts` retain their normal Babel behavior.

| Header | Meaning |
|---|---|
| `:hosts @web` | Ordered selection; required |
| `:exclude web-02` | Additional exclusions |
| `:dir /srv/app` | Override the remote working directory, preserving routing |
| `:concurrency 4` | Maximum active background jobs; default 4 |
| `:timeout 60` | Per-job deadline including pool waiting and connection setup; default 60 seconds |
| `:fail-fast yes` | Skip jobs still queued after a failure; already running jobs finish |
| `:renderer digest` | `digest`, `per-host`, `table`, or `combined` |
| `:execution foreground` | Serial execution in this Emacs, with interactive authentication |

Shell blocks use `:results output` so a real process exit code is preserved.
Python defaults to `python3` (override with `:python`) and supports output and value results. Variables and noweb are expanded once
through Org, after execution approval. Routing headers must be literal data;
dynamic Lisp in `:hosts` from the earlier local extension is replaced by inventory
groups or an explicitly generated inventory.

Persistent Babel sessions, secondary async extensions, `:file`, `:post`, `:stdin`,
`:cmdline` and result caching are rejected rather than silently given different
multihost semantics. Results use `output` or `value` with replacement; select
presentation with `:renderer`. Other result modes such as `silent`, `append` and
`raw` are rejected. Indirect Babel calls cannot submit a Multihost run: execute
its source block explicitly. Backends that run in the local editor, including Emacs Lisp,
are rejected. Code evaluation during export is rejected: run the block explicitly
and then export its stored results. See [example runbooks](examples/operations.org).

## Retained connections and remote completion

Background jobs now reuse persistent Emacs workers and their TRAMP connections.
Connection setup, remote execution and completion queries run outside the main
editor. `w` prepares selected hosts; `C` shows worker state and completed requests.
`multihost-connection-limit` bounds the whole pool (default four), with one active
request per connection. Idle workers expire after 300 seconds by default. Changes
to the working directory do not require a new connection.

In the body of an Org shell block with `:hosts`, place point after a command or
filename prefix and run `M-x multihost-org-completion-enable`. Use `M-TAB` for
cached remote suggestions. A missing prefix is fetched asynchronously; invoke
completion again once replies arrive. `C-c '` source editing inherits this opt-in.
Suggestions show which hosts supplied them. Choose `union` or `intersection` with
`multihost-completion-policy`; incomplete responses cannot produce an intersection.

This uses remote Bash `compgen` for simple command names and filenames. It requires
Bash on the target and does not implement option-specific `bash-completion` or
load interactive shell startup files. Completion is off until explicitly enabled.
Foreground commands and ordinary TRAMP file browsing retain their synchronous
behavior. See [connection controls, completion and measurements](docs/connections-and-completion.md).

## Results, failures and history

The dashboard shows queued, running, succeeded, failed, timed-out, skipped and
cancelled jobs. `waiting-pool` distinguishes work awaiting a shared connection
slot from work already assigned to a worker. Results include the process exit code, stdout, stderr and duration.
A failed shell command is not considered successful merely because Babel returned
a string. A worker result larger than 64 MiB is rejected as a protocol failure;
design checks to return bounded summaries instead of bulk data dumps.

| Dashboard key | Action |
|---|---|
| `RET` | Separate buffer for the host at point |
| `a` / `d` | Combined output / grouped digest |
| `c` | Cancel the run's queued jobs and local workers |
| `r` | Create a new run for unsuccessful jobs |
| `e` | Export a private Org report |
| `g` | Refresh |

The dashboard updates as hosts finish. Output becomes available when each Babel
invocation completes; these are result buffers, not streaming terminal emulators.
Use `s` from the inventory for interactive programs and shell state.

Completed results are inserted into the source block only if its source is still
unchanged and the run has not been superseded by a newer submission. Edited or
closed runbooks do not lose their results: the run history retains them.

Run history is stored below `multihost-state-directory`, normally
`~/.emacs.d/multihost/`, with private directory/file permissions. It includes host
metadata, timestamps and output, plus a source hash. Code requests are removed
after completion; the source body is not saved in the audit record. Retrying uses
the in-memory source snapshot; after an Emacs restart, submit the original runbook
again. Interrupted records are not resumed automatically.

Cancellation and timeouts stop local work. They cannot prove that a remote
daemonized process stopped, nor undo operations already completed. Serial mode
is a scheduling guarantee, not a transaction. Local history and exported output
may be sensitive; neither is a tamper-proof compliance log. Nothing is uploaded
automatically.

## SSH and CyberArk PSMP

For normal background work, workers need authentication that works without an
interactive minibuffer: for example an already authorized SSH agent. Workers use
persistent, isolated `emacs -Q` processes and do not load your entire personal init file. Use
`multihost-worker-init-file` for a small, trusted configuration file when custom
TRAMP or Babel settings are needed.

For interactive authentication, use `:execution foreground` or
`M-x multihost-org-execute-foreground`. This runs serially in the current Emacs
and uses its TRAMP authentication flow. It blocks while executing, has no hard
background deadline, and can be interrupted with `C-g`. The explicit command
overrides background concurrency/deadline settings; the header form rejects
conflicting settings.

PSMP is accessed through an organization-approved SSH alias. Multihost does not
change CyberArk policy or enable ControlMaster automatically. The pool reuses each worker's TRAMP shell; it does not need to add SSH connection sharing. A successful
foreground login does not prove that background workers can reuse it.
**No live CyberArk deployment has been certified by the local SSH tests.**
[PSMP setup, official references and deployment acceptance checks](docs/psmp.md)
explain the policy, MFA and audit distinctions.

## Development and verification

```sh
make check          # warning-free byte compilation and ERT unit tests
make integration    # real SSH + TRAMP + Babel on two private loopback endpoints
```

Integration prerequisites: Linux, Python 3, OpenSSH server/client, `/run/sshd`
available and loopback ports 22261/22262 free. The fixture creates its own keys,
trust file and SSH configuration under `.runtime`; it does not use your servers.
The two endpoints share a kernel. They test scheduling and transport behavior,
not WAN performance or CyberArk recording. See [testing](docs/testing.md),
[architecture](docs/architecture.md) and [contributing](CONTRIBUTING.md).

The release passed **128 unit tests and 20 real-SSH integration tests** on
Emacs 30.1. [Recorded validation](docs/validation.json) includes source and log hashes; [GitHub Actions](https://github.com/SweatierKey/emacs-multihost/actions)
runs the suite on Ubuntu 24.04 and Debian 13.

## License and origin

GPL-3.0-or-later. This project develops the concept of the local `ob-multihost`
extension supplied by SweatierKey into a separate package with an inventory,
scheduler, explicit execution contract and test suite. The original personal
Emacs installation is not modified by this repository.

The bundled asciinema player retains its [Apache-2.0 license](docs/player/LICENSE);
its version and file hashes are recorded in [player provenance](docs/player/provenance.json).
