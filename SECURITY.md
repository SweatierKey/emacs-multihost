# Security and operational boundaries

This tool executes code with the remote privileges your SSH/TRAMP configuration
provides. It is not an authorization layer, secret vault, transaction manager or
replacement for CyberArk audit.

Inventories are parsed as JSON data. Remote routing is validated before dispatch;
unknown selectors, ambiguous directories and local-only transports are rejected.
Worker requests and run history use private storage. Worker startup configuration
is trusted executable Lisp supplied explicitly by the operator.
Requests contain expanded code and parameters while a job runs. Normal completion,
cancellation and timeout remove them; an abrupt editor/OS crash may leave private
request files below `multihost-state-directory`. Inspect retention after a crash. Babel output
is buffered until completion; the 64 MiB protocol limit is not a streaming memory
limit on the child interpreter.

Retained workers preserve authenticated TRAMP shells until idle expiry or explicit
closure. Connection identity includes the full TRAMP prefix and trusted startup
configuration; working directories remain request-specific. Batch authentication
prompts fail explicitly and are not consumed as RPC input.

Remote completion is an explicit opt-in. Queries execute a fixed Bash program with
literal prefix arguments, never the text being edited. Candidate and output limits
bound responses, and cached candidates stay in memory in the editing buffer.
Completion does not evaluate Org header Lisp or imply approval to run the block.

Org approval occurs before expansion of variables and noweb references. As with
ordinary Babel, approving a block also approves its dependencies. Preview does not
evaluate header Lisp. Output is rendered as data, never executable Org markup.

Results may contain secrets printed by your scripts. Permissions limit access but
cannot reliably redact arbitrary output. Avoid secrets in script text and results;
manage retention and exported reports under your organization's rules.

Stopping a local SSH worker does not prove all remote descendants stopped. Verify
the target after cancellation or an ambiguous transport failure before retrying
a non-idempotent operation. There are no automatic retries of failed operations.

Report sensitive vulnerabilities through the repository's private vulnerability
reporting facility when available, or contact the maintainer privately through
their GitHub profile. Do not post secrets or exploitable production details in a
public issue.
