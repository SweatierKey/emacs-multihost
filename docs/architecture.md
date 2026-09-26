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
4. `multihost-connection.el` owns the globally bounded pool, connection identities,
   FIFO request queues, private RPC files, idle eviction and worker lifetimes.
5. `multihost-worker.el` invokes Babel with a remote directory and records actual
   command status. Worker exit status and remote command exit status are distinct.
6. `multihost.el` presents the run list, per-host dashboard, individual results,
   combined results, grouped results and exports. `multihost-connections-ui.el`
   displays retained connections and explicit asynchronous initialization.
7. `multihost-compgen.el` runs bounded, fixed Bash queries in the worker.
   `multihost-completion.el` supplies cached CAPF candidates, host annotations,
   debounce and stale-response handling in the editor. Org supplies a literal,
   non-evaluating context resolver for both the runbook and its source edit buffer.

## Execution contract

Parallelism is bounded; concurrency 1 waits for each job to finish before starting
the next in selection order. Fail-fast skips jobs still queued when a failure is
observed; jobs already running may finish. Retrying failures creates a new run and
does not rewrite the old result. Cancellation stops local workers and queued work.
It does not prove a detached remote process has stopped.

The background timeout covers pool queue waiting, authentication, connection
setup and execution. An active timeout or cancellation retires the worker; normal
completion keeps its TRAMP connection for subsequent jobs and completion queries.
Different working directories share a connection, but Babel sessions remain
isolated. Global pool capacity and per-run concurrency both constrain scheduling.
Interrupted requests are never replayed automatically.
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

See [the connection and completion contract](connections-and-completion.md) for
identity, authentication, cache limits and the boundaries of editor responsiveness.
