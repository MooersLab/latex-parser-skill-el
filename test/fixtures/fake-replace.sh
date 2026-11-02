#!/bin/sh
# Stand-in for an external replacement tool.  Reads the file named in $1
# and upper-cases the word alpha.
sed 's/alpha/ALPHA/g' "$1"
