# Persistent TRAMP connections and remote completion

Multihost 1.1 keeps a separate Emacs process for each active remote connection.
That process owns the ordinary TRAMP shell and its connection properties. Jobs,
connection warm-up and completion requests reuse it. The main editor schedules
work and displays replies; it does not run TRAMP connection setup for these
background operations.

This avoids repeating Emacs startup and TRAMP initialization for every block.
It also keeps a slow login or remote command out of the editor's event loop.
It does not make the first network handshake instantaneous. Foreground execution,
ordinary TRAMP Dired/shell commands, and native Babel dependency expansion still
have their normal synchronous behavior.

## Connection controls

In `M-x multihost`, mark hosts with `m` or `T`, then press `w` to initialize their
connections asynchronously. A table reports success or failure for every host.
Press `C`, or run `M-x multihost-connections`, to see the retained workers.
`g` refreshes that view without connecting. `k` closes the connection at point
and cancels its outstanding requests. Verify interrupted remote operations before
retrying them.

- `multihost-connection-limit` limits worker processes across all runs, warm-ups
  and completion requests. The default is four.
- One request runs at a time in each worker. Jobs targeting the same connection
  wait for that worker; different connections can run concurrently.
- `multihost-connection-idle-timeout` defaults to 300 seconds. Idle workers can
  also be evicted to make room for another destination.
- Per-request deadlines include time in the pool queue, initialization and
  execution. A timeout or active cancellation retires that worker. Interrupted
  work is never automatically replayed.

The connection identity preserves the complete TRAMP method, user, host, port and
hop prefix. The working directory belongs to each request. Changes to the trusted
worker init file invalidate reuse. Close a connection explicitly after changing
SSH routing or authentication configuration that is external to that file.

Retaining a TRAMP transport does not enable persistent Babel `:session` state:
each block still runs under the documented isolated execution contract. A `cd`
or exported variable in one block does not become implicit state in the next.

## Completion while writing a runbook

Place point in the body of a shell block, after a simple command or filename
prefix:

```org
#+begin_src sh :hosts @web :dir /srv/app
cat conf
#+end_src
```

Run `M-x multihost-org-completion-enable`. This is an explicit request to query
the selected hosts. Once replies arrive, use `M-TAB` (`completion-at-point`) or
your existing CAPF completion UI. You can also use `C-c '` to edit the block in
`sh-mode`; an enabled Org buffer passes the completion opt-in to that edit buffer.
Enabling completion directly inside the edit buffer is supported too.

The editor's working directory remains local when the runbook is local. Host
selection comes from literal `:hosts`, `:exclude` and `:dir` headers; computing
that selection does not evaluate the block, variables or header Lisp.

The completion function returns cached candidates immediately. Missing or expired
data is requested asynchronously after a debounce. The first invocation can show
no candidates while the request is pending; invoke completion again after replies
arrive. There is no automatic insertion from a late reply. Changed prefixes,
changed target selections and closed buffers cannot receive stale insertions.

Candidate annotations identify the hosts that returned each suggestion. Configure
`multihost-completion-policy` to choose:

- `union`: suggestions observed on any selected host, annotated with their host
  coverage and any incomplete results.
- `intersection`: suggestions confirmed on every selected host. No intersection
  is presented while a host is pending, failed or has a truncated response.

Use `M-x multihost-completion-refresh` to explicitly renew the current query and
`M-x multihost-org-completion-disable` to stop completion in this buffer. The
completion status distinguishes pending, failed, empty and truncated responses.
`M-x multihost-completion-status` displays the current summary;
`M-x multihost-completion-inspect` opens a snapshot with per-host errors and
response details. Neither command starts a connection.
TTL, debounce, timeout and candidate/output limits are customizable under the
`multihost-completion` group.

## What `compgen` means here

Queries use a fixed Bash program and pass the prefix as a literal positional
argument. Command-name completion uses `compgen -c`; filename completion uses
`compgen -f`. The query requires Bash on the target, even when the block itself
uses `sh`. Missing Bash or a denied operation is reported as failure.

This release handles simple unquoted tokens. Shell substitutions, operators,
quoted or escaped prefixes and option-specific completion are outside the
contract. Candidates are quoted for safe insertion; filenames containing control
characters are excluded. Input text is never evaluated as a shell program.

The query starts Bash with startup files disabled. It does not load interactive
aliases, user-defined completion functions or the `bash-completion` framework.
It reflects the worker's remote command environment and requested directory,
not a separately opened terminal's mutable shell state.

## PSMP and authentication

The pool does not require SSH ControlMaster and does not change gateway policy.
It reuses the existing TRAMP shell inside the same worker. Background workers
need authentication that can complete without an interactive editor prompt.
Interactive requests are rejected rather than interpreted as protocol input.
An existing login in the main Emacs does not transfer authentication to a worker.

The foreground command remains available for interactive TRAMP authentication;
it can block the editor and has no hard background deadline. This release does
not claim asynchronous MFA support or compatibility with an untested PSMP policy.
The shell and temporary-file requirements described in [PSMP deployment](psmp.md)
still apply to a retained connection.

## Evidence and reproduction

[Connection measurements](connection-performance.json) compare the 1.0 worker
model with persistent workers on the same loopback fixture. They record source
hashes, worker PIDs, remote SSH connection identities, cold/repeated timings and
parent timer gaps. Timer gaps are a responsiveness proxy, not a measurement of
every possible GUI operation. No test requires an arbitrary speedup percentage.

On the recorded Emacs 30.1 / TRAMP 2.7.1 run, using two loopback endpoints:

| Measurement | 1.0 background workers | 1.1 persistent pool |
|---|---:|---:|
| First call (seconds) | 2.349 | 2.350 |
| Median of five repeated calls (seconds) | 2.308 | 0.800 |
| Worker processes across six calls | 6 | 1 |
| SSH connections across six calls | 6 | 1 |
| Largest observed parent timer gap (milliseconds) | 20.79 | 20.26 |

Both background models kept delivering parent timers. The measured improvement
is the cost of subsequent calls: the pool retains the Emacs process and SSH
connection instead of establishing them again. The cold handshake still costs
about the same. These local observations are not predictions for WAN or PSMP
latency. A separate synchronous TRAMP reference and deliberately delayed login
are also recorded in the JSON.

```sh
python3 tools/benchmark-connections.py --label persistent-pool
make integration
```

Use the benchmark's `--source` argument with a checkout of tag `v1.0.0` to repeat
the comparison. Do not run two laboratory commands simultaneously: they share
the fixture's loopback ports.
