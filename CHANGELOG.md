# Changelog

## 1.0.0

- Data-only JSON inventories, ordered selectors, groups, exclusions and explicit
  TRAMP endpoints with preserved users, ports and hops.
- Asynchronous per-host Babel workers, bounded concurrency, ordered serial mode,
  deadlines, fail-fast dispatch, cancellation and explicit selective retry.
- Real process status for shell/Python, separate stdout/stderr, grouped and
  per-host result views, exports and private persistent run history.
- Org `:hosts` integration with native evaluation policy, non-evaluating preview,
  one-time variable/noweb expansion and protection against stale result insertion.
- Explicit foreground execution for interactive TRAMP authentication; SSH/PSMP
  configuration and deployment limitations documented.
- Unit, real-SSH integration and interactive UI verification tools.

This release replaces the local 0.2 implementation. Routing headers are data-only;
unsupported backends and ambiguous Babel execution options now fail before
dispatch. See README for the complete supported contract and migration notes.
