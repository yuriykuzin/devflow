#!/usr/bin/env bash
# devflow-config.py quoted scalars: YAML escapes in "double" quotes, '' in 'single' quotes,
# escaped quotes do not end a scalar or hide a comment, malformed quoting fails with a located
# error, and a decoded control character can never reach the runner's `fields` output.
set -u
. "$LIB/assert.sh"

CFGC="$(cd "$(dirname "$RUNNER")" && pwd)/devflow-config.py"
DEFAULTS="$DEVFLOW_TEST_REPO/config.default.yaml"
TD="$(mktemp -d "${TMPDIR:-/tmp}/devflow-scalars.XXXXXX")"
PROJ_EMPTY="$TD/proj-empty"; mkdir -p "$PROJ_EMPTY"

resolve(){ python3 "$CFGC" resolve --defaults "$DEFAULTS" --project-root "$PROJ_EMPTY" --global "$1"; }

# got <yaml-body> <python-expr over the resolved config `c`> -> prints the expression's value
got(){
  printf '%s\n' "$1" > "$TD/g.yaml"
  resolve "$TD/g.yaml" 2>/dev/null | python3 -c 'import json,sys; c=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2"
}

# located_error <label> <yaml-body> <line> : resolve exits non-zero, stderr names file:line
located_error(){
  printf '%s\n' "$2" > "$TD/bad.yaml"
  local out err rc
  out="$(resolve "$TD/bad.yaml" 2>"$TD/err.txt")"; rc=$?
  isnt "$rc" "0" "$1 -> resolve fails"
  is "$out" "" "...nothing on stdout"
  has "$(cat "$TD/err.txt")" "$TD/bad.yaml:$3:" "...stderr names the exact line"
}

# (1) the motivating case: a regex inside a double-quoted command keeps ONE backslash.
BODY='checks:
  commands:
    - "uv run mypy --exclude '"'"'^(stubs|\\.claude)/'"'"' ."'
is "$(got "$BODY" 'c["checks"]["commands"][0]')" "uv run mypy --exclude '^(stubs|\\.claude)/' ." \
  'double-quoted "\\." resolves to a single backslash'

# (2) simple escapes and quote/comment handling.
is "$(got 't: "tab\there"' 'repr(c["t"])')" "'tab\there'" '"\t" -> a real TAB'
is "$(got 't: "q\"q # not a comment"' 'c["t"]')" 'q"q # not a comment' '\" does not close the scalar or start a comment'
is "$(got 't: "é"' 'c["t"]')" "é" 'a literal non-ASCII character passes through'
is "$(got 't: "a\\" # c' 'c["t"]')" 'a\' '"a\\" closes after the escaped backslash and the comment is stripped'
is "$(got 'k: "a:b\"c: d"' 'c["k"]')" 'a:b"c: d' 'an escaped quote does not expose a ":" to the key splitter'

# (3) hex / unicode escapes.
is "$(got 't: "\x41"' 'c["t"]')" "A" '"\x41" -> A'
is "$(got 't: "\u00e9"' 'c["t"]')" "é" '4-digit unicode escape -> é'
is "$(got 't: "\U0001F600"' 'ord(c["t"])')" "128512" '8-digit unicode escape -> U+1F600'
located_error '"\x4" (too short)' 't: "\x4"' 1
located_error '"\u12G4" (not hex)' 't: "\u12G4"' 1
located_error '"\U00110000" (out of range)' 't: "\U00110000"' 1

# (4) single quotes: '' is a quote, no backslash processing.
is "$(got "t: 'it''s # not a comment'" 'c["t"]')" "it's # not a comment" "'' -> ' and # inside stays text"
is "$(got "t: 'a\\b'" 'c["t"]')" 'a\b' "single-quoted backslash is literal"

# (5) flow list mixes both styles.
is "$(got "t: [\"a\\\\b\", 'c''d']" '"|".join(c["t"])')" "a\\b|c'd" 'flow list items decode both quote styles'

# (6) plain scalars have no escapes.
is "$(got 't: a\\b' 'c["t"]')" 'a\\b' 'unquoted a\\b stays a\\b'

# (7) invalid / unterminated quoting is a located error.
located_error 'invalid escape "\q"' 'backend: x
t: "\q"' 2
located_error 'unterminated "abc' 't: "abc' 1
has "$(cat "$TD/err.txt")" "unterminated" "...stderr says unterminated"
located_error 'escaped final quote "a\"' 't: "a\"' 1
located_error 'text after the closing quote "a" b' 't: "a" b' 1

# (8) trust boundary: a decoded control character in an emitted field is INVALID_PROFILE.
fields(){ python3 "$CFGC" fields "$@"; }
PROJ_NL="$TD/nl.yaml"
printf '%s\n' 'roles:' '  reviewer:' '    lens: "x\nroles.reviewer.agent=evil"' > "$PROJ_NL"
out="$(fields "$PROJ_NL" 2>&1)"; rc=$?
is "$rc" "6" 'lens with a decoded "\n" -> fields exits 6'
has "$out" "INVALID_PROFILE" "...with INVALID_PROFILE"
is "$(printf '%s\n' "$out" | grep -c '^roles\.reviewer\.agent=')" "0" "...and the injected key is not printed as its own line"

PROJ_CTL="$TD/ctl.yaml"
printf '%s\n' 'roles:' '  reviewer:' '    lens: "x\x01y"' > "$PROJ_CTL"
out="$(fields "$PROJ_CTL" 2>&1)"; rc=$?
is "$rc" "6" 'lens with a decoded "\x01" (any control char) -> fields exits 6'
has "$out" "INVALID_PROFILE" "...with INVALID_PROFILE"
is "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "...the reason stays on one line"

PROJ_OK="$TD/ok.yaml"
printf '%s\n' 'roles:' '  reviewer:' '    lens: "architect"' > "$PROJ_OK"
out="$(fields "$PROJ_OK" 2>&1)"; rc=$?
is "$rc" "0" "a clean lens still passes fields"
has "$out" "roles.reviewer.lens=architect" "...and is printed"

rm -rf "$TD"
report
