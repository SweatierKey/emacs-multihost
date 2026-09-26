# Contributing

Run `make check` before submitting a change. For execution, routing or state
changes, run `make integration` on Linux with the documented SSH prerequisites.
Add tests that demonstrate behavior or a regression, not copies of implementation.

Keep credentials and real inventories out of fixtures. Preserve native Org policy,
SSH host-key verification, explicit host order and the distinction between command
failure and transport failure. Never implement a local fallback for remote work.

New language backends need evidence that execution occurs on the target, reliable
exit status and stderr capture, cancellation/timeout tests, and a documented
parameter contract. A backend accepting `:dir` is not sufficient evidence.

CyberArk compatibility claims need a named tested deployment/version, relevant
policy settings and recording/audit observations. A loopback SSH fixture is not
a PSMP simulator. Report issues with anonymized configuration and minimal commands;
do not attach secrets or unredacted operational output.

The package uses lexical binding, standard Emacs libraries, ERT and Python's
standard library for the fixture tools. Avoid adding dependencies for cosmetic UI
features. Changes should preserve operation with and without Vertico/Marginalia.
