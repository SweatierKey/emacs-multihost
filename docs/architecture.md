# Architecture

Multihost treats a run as a fixed plan, a set of per-host jobs, and recorded results.
The editor remains responsive while isolated Emacs workers execute ordinary Org
Babel backends through TRAMP. There is no remote agent and no password database.

1. `multihost-inventory.el` validates data-only inventories and resolves selectors
   in a deterministic order. Validation does not connect to hosts.
2. `ob-multihost.el` integrates with Org, checks execution policy and supported
   parameters, expands the source once, and submits the resolved plan.
3. `multihost-engine.el` owns scheduling, state transitions, time limits,
   cancellation, retries and private run history.
4. `multihost-worker.el` invokes Babel with a remote directory and records actual
   command status. Worker exit status and remote command exit status are distinct.
5. `multihost.el` presents the run list, per-host dashboard, individual results,
   combined results, grouped results and exports.

## Execution contract

Parallelism is bounded; concurrency 1 waits for each job to finish before starting
the next in selection order. Fail-fast skips jobs still queued when a failure is
observed; jobs already running may finish. Retrying failures creates a new run and
does not rewrite the old result. Cancellation stops local workers and queued work.
It does not prove a detached remote process has stopped.

The background timeout covers authentication, connection setup and execution.
Background workers require authentication that works without a minibuffer.
The explicit foreground path uses the current Emacs/TRAMP environment for
interactive authentication and serial execution. Its interaction and timeout
semantics are documented separately; a successful foreground login is not proof
that a batch worker can authenticate.

## Boundaries

The initial supported languages are shell and Python. Backends that execute in
the local editor, such as Emacs Lisp, cannot be made remote by assigning `:dir`
and are rejected. Persistent Babel sessions and asynchronous Babel extensions
are not silently combined with the scheduler. Unsupported headers fail before
dispatch. Normal blocks without `:hosts` retain ordinary Org behavior.

Results are available after each Babel invocation completes. The dashboard shows
job state changes as they happen; this is not a streaming terminal emulator.
Remote interactive terminals and file editing use the ordinary Emacs/TRAMP tools.

Run records are local operational history, not tamper-proof compliance evidence.
Commands and output may contain confidential information. Runtime storage uses
private directories and files; nothing is uploaded automatically.
