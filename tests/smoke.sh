#!/usr/bin/env bash
# sieve smoke test: a scratch tree with known answers, then the behaviour is checked.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
SIEVE="python3 $HERE/sieve"
T=$(mktemp -d)
fails=0

check() {
  if [ "$2" = "$3" ]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

mkdir -p "$T/sub" "$T/.git" "$T/node_modules"
printf 'the sieve writes code\nnothing here\nanother sieve line\n' > "$T/sieve-notes.txt"
printf 'sieve\n' > "$T/sub/c.md"
printf 'sieve in git\n' > "$T/.git/secret.txt"
printf 'sieve in node\n' > "$T/node_modules/x.js"
printf 'binary\000sieve\n' > "$T/bin.dat"
printf 'call foo(bar) now\n' > "$T/parens.txt"

cd "$T" || exit 1

out=$($SIEVE sieve --color=never)
check "name hit found"       "1" "$(printf '%s' "$out" | grep -c 'sieve-notes.txt name+content')"
check "content hit found"    "1" "$(printf '%s' "$out" | grep -c 'sub/c.md content')"
check "git not walked"       "0" "$(printf '%s' "$out" | grep -c 'secret.txt')"
check "node_modules skipped" "0" "$(printf '%s' "$out" | grep -c 'x.js')"
check "summary printed"      "1" "$(printf '%s' "$out" | grep -c '^sieve:')"
check "line numbers shown"   "1" "$(printf '%s' "$out" | grep -c '^     1: the sieve writes code')"

$SIEVE sieve --color=never >/dev/null 2>&1; check "exit 0 on a match"  "0" "$?"
$SIEVE zzznope --color=never >/dev/null 2>&1
check "exit 1 on nothing" "1" "$?"
$SIEVE >/dev/null 2>&1
check "exit 2 on misuse" "2" "$?"

n=$($SIEVE sieve -c --color=never | grep -c '^ *[0-9]*  ')
check "count mode lists two files" "2" "$n"

lit=$($SIEVE --text 'foo(bar)' --color=never | grep -c 'call foo(bar) now')
check "literal pattern, no regex surprise" "1" "$lit"

esc=$($SIEVE --text sieve --color=never | grep -c "$(printf '\033')")
check "no escape codes into a pipe" "0" "$esc"

$SIEVE --text sieve --named '*.md' --color=never >/dev/null 2>&1
check "named filter accepts a glob" "0" "$?"

rm -rf "$T"
if [ "$fails" -eq 0 ]; then
  echo
  echo "all checks passed"
  exit 0
fi
echo
echo "$fails check(s) failed"
exit 1
