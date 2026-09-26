#!/bin/sh
# Real SSH tests.  Never installs packages or changes personal SSH/Emacs files.
# Set MULTIHOST_TEST_SELECTOR to an ERT test-name regexp for a focused rerun.
set -eu
study_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$study_root"
trap 'python3 "$study_root/tools/lab.py" stop' EXIT HUP INT TERM
python3 tools/lab.py start
export MULTIHOST_INTEGRATION=1
export MULTIHOST_LAB_ROOT="$study_root/.runtime/lab"
export MULTIHOST_LAB_CONFIG="$MULTIHOST_LAB_ROOT/ssh_config"
export PATH="$MULTIHOST_LAB_ROOT/bin:$PATH"
"${EMACS:-emacs}" --batch -Q -L . -L test \
  -l "$MULTIHOST_LAB_ROOT/worker-init.el" \
  -l test/multihost-integration-test.el \
  -l test/multihost-org-integration-test.el \
  -l test/multihost-connection-integration-test.el \
  --eval '(ert-run-tests-batch-and-exit (or (getenv "MULTIHOST_TEST_SELECTOR") t))'
