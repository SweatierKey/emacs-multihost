EMACS ?= emacs

.PHONY: test compile check integration clean
test:
	$(EMACS) -Q --batch -L . -L test -l test/run-tests.el
compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t load-prefer-newer t)' -f batch-byte-compile $(wildcard *.el)
check: compile test
integration:
	EMACS=$(EMACS) bash tools/test-integration.sh
clean:
	rm -f *.elc test/*.elc
