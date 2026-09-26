EMACS ?= emacs

.PHONY: test compile check integration clean
test:
	$(EMACS) -Q --batch -L . -L test -l test/run-tests.el
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile multihost-inventory.el multihost-worker.el multihost-engine.el multihost.el ob-multihost.el
check: compile test
integration:
	EMACS=$(EMACS) bash tools/test-integration.sh
clean:
	rm -f *.elc test/*.elc
