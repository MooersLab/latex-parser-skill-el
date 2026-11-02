# Makefile for latex-parser-skill
#
# make            lint, compile, test and build the Info manual
# make test       run the offline ERT suite (fake backend, no network)
# make live-test  run the live tests too (see test/latex-parser-skill-live-test.el)
# make check-prompt  compare prompts/transcript-parser.md with SKILL=path/to/SKILL.md

EMACS ?= emacs
BATCH := $(EMACS) -Q --batch -L .
EL    := $(wildcard latex-parser-skill*.el)
TESTS := $(wildcard test/*-test.el)
SKILL ?= $(HOME)/.claude/skills/transcript-parser/SKILL.md

.PHONY: all compile test live-test lint checkdoc docs sync-prompt check-prompt indent clean

all: lint compile test docs

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(EL)

test:
	$(BATCH) -L test -l test/test-helper.el $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit

live-test:
	LPS_LIVE=1 $(MAKE) test

# Installs package-lint from MELPA into .elpa on first use.
# Set PACKAGE_LINT_DIR to a checkout of package-lint to work offline.
lint:
	$(BATCH) -l scripts/lint.el $(EL)

docs: docs/latex-parser-skill.info

docs/latex-parser-skill.texi: docs/latex-parser-skill.org docs/tutorial.org docs/keybindings.org
	$(EMACS) -Q --batch -l scripts/export-texinfo.el $<

docs/latex-parser-skill.info: docs/latex-parser-skill.texi
	makeinfo --no-split $< -o $@

sync-prompt:
	sh scripts/sync-prompt.sh "$(SKILL)"

# Compare the bundled prompt with an installed skill (default $(SKILL)).
check-prompt:
	LPS_SKILL_FILE="$(SKILL)" $(BATCH) -L test -l test/test-helper.el -l test/latex-parser-skill-backend-test.el --eval '(ert-run-tests-batch-and-exit "lps-prompt-matches-installed-skill")'

indent:
	$(BATCH) -L test -l test/test-helper.el --eval '(setq make-backup-files nil)' --eval '(setq-default indent-tabs-mode nil)' --eval '(dolist (f (list $(foreach e,$(EL) $(TESTS) test/test-helper.el,"$(e)"))) (with-current-buffer (find-file-noselect f) (emacs-lisp-mode) (indent-region (point-min) (point-max)) (untabify (point-min) (point-max)) (delete-trailing-whitespace) (save-buffer)))'

clean:
	rm -f *.elc test/*.elc docs/*.info
