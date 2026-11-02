#!/bin/sh
# Stand-in for the claude program.  Records its arguments and echoes a
# fixed LaTeX fragment that includes the first line of standard input.
printf '%s\n' "$@" > "${FAKE_CLAUDE_ARGS:-/dev/null}"
first=$(head -n 1)
if [ "$FAKE_CLAUDE_FAIL" = "1" ]; then
  echo "simulated failure" >&2
  exit 3
fi
if [ -n "$FAKE_CLAUDE_SLEEP" ]; then
  sleep "$FAKE_CLAUDE_SLEEP"
fi
printf '\\subsubsection{Echo}\n\\index{echo}\n\n%s\n' "$first"
