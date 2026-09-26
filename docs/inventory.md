# Inventory and selection

An inventory is a local JSON file. It is data, never executable Lisp. Commit a
sanitized inventory beside the runbook, or keep an operational inventory outside
the repository. Do not store passwords, tokens, private keys, or other secrets in
it. SSH configuration and TRAMP remain responsible for authentication, host key
verification, proxies, and CyberArk PSMP routing.

```json
{
  "version": 1,
  "hosts": [
    {"name": "web-01", "connection": "company-web-01", "groups": ["prod", "web"]},
    {"name": "db-01", "connection": "/ssh:company-db-01:/srv/", "groups": ["prod", "db"]}
  ]
}
```

Each entry needs a unique `name` and a `connection`. Optional `groups` is an array
of names; optional `description` is a single-line string. Unknown fields and
duplicate JSON keys are errors, so a misspelled setting cannot silently change
the intended target set. An empty inventory is an error. Host and group names
use letters, digits, dots, underscores and hyphens, starting with a letter or
digit.

Prefer a connection alias from `~/.ssh/config`, especially for PSMP. Multihost
turns `company-web-01` into `/ssh:company-web-01:~/`. Complete TRAMP directories
also work: `/ssh:ops@web-01#2222:/srv/` or
`/ssh:bastion|ssh:ops@web-01#2222:/srv/`. User, port, explicit hops, and working
directory survive into the execution plan. Loading and selecting hosts do not
open SSH connections or change TRAMP's proxy configuration.

Direct `ssh`, `sshx`, `scp`, `scpx`, and `sftp` connections are accepted.
`sudo` and `doas` are accepted only after an explicit SSH hop, for example
`/ssh:company-web-01|sudo:root@company-web-01:/srv/`. Direct local privilege
paths such as `/sudo:root@localhost:/` are rejected. Inventory validation
checks routing syntax; availability and authentication are checked by execution.

## Choosing targets

Selectors in `:hosts` are separated by whitespace:

| Selector | Meaning |
| --- | --- |
| `web-01 db-01` | These names, in this order |
| `@prod` | Members of the `prod` group, in inventory order |
| `web-*` | Names matching this case-sensitive shell-style glob |
| `*` | All inventory hosts, in inventory order |
| `@prod !db-01` | The group, excluding `db-01` |
| `db-01 @prod` | Database first, then remaining group members |

Expansion proceeds left to right; repeated hosts retain their first position.
Exclusions apply to the complete selection, wherever they appear. A misspelled
name, unknown group, unmatched glob, or empty final selection is an error before
execution. This makes the declared order useful for serial rollouts.

With an inventory loaded, literal names must exist in it. Without an inventory,
literal SSH aliases or complete TRAMP directory names can be used directly;
groups and globs require an inventory. Put connections whose directories contain
spaces in the JSON inventory and select their simple names.

Routing headers in runbooks must be literal: `:hosts web-01 db-01` or
`:hosts @prod`. Lisp-valued routing such as `:hosts (list "web-01" "db-01")`
is rejected before evaluation. This deliberately differs from the original
personal `ob-multihost.el`: preview and execution must agree on the target set
without executing code to discover it. Put dynamic inventory generation in an
explicit external step that writes the JSON inventory before previewing a run.

After Org's evaluation policy approves execution, ordinary `:var` and noweb
expressions can be resolved. Preview does not resolve them. As with ordinary Org
Babel, open and execute only runbooks you trust.

The Lisp selection API separately accepts already evaluated strings, lists, and
vectors, so a Lisp caller can pass `("web-01" "db-01")`. Its parser never
evaluates a string as Lisp; symbols and numbers are rejected rather than
converted into accidental destinations.

## Working directories

Without `:dir`, each host retains its inventory connection's directory. An SSH
alias defaults to `~/`. A target-local `:dir /srv/operations` or `:dir ~/checks`
overrides that directory on every selected host, preserving all routing details.

A remote `:dir /ssh:other:/srv/` is deliberately rejected. Put remote routing in
the inventory's `connection` field, and use `:dir /srv/` for the target-local
directory. This differs from the original personal `ob-multihost.el`, which
rewrote remote `:dir` values and discarded their explicit user, port, and hops.

The expanded host records are independent copies. Changing the inventory after
planning cannot redirect an already prepared run.

## Lisp API

```elisp
(setq hosts (multihost-inventory-load "/path/to/inventory.json"))
(setq selected (multihost-select-hosts "db-01 @prod" hosts "web-02"))
(multihost-host-directory (car selected) "/srv/checks")
```

The optional third argument to `multihost-select-hosts` is an additional exclusion
list. Programmatic callers can construct an endpoint with
`(make-multihost-host :name "web" :connection "company-web")`.
