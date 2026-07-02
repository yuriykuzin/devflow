# Tiny TAP-ish assertion + reporting helpers. Sourced by every case.
# Usage: is "$got" "$want" "label" ; has "$haystack" "needle" "label" ; ok "[ -f x ]" "label"
T_PASS=0; T_FAIL=0

_pass(){ echo "  ok   - $1"; T_PASS=$((T_PASS+1)); }
_fail(){ echo "  FAIL - $1"; T_FAIL=$((T_FAIL+1)); }

is(){   # is GOT WANT LABEL
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 (got:'$1' want:'$2')"; fi
}
isnt(){ # isnt GOT NOTWANT LABEL
  if [ "$1" != "$2" ]; then _pass "$3"; else _fail "$3 (got:'$1' should differ)"; fi
}
has(){  # has HAYSTACK NEEDLE LABEL
  if printf '%s' "$1" | grep -qF -- "$2"; then _pass "$3"; else _fail "$3 (need '$2' in: $1)"; fi
}
hasnt(){ # hasnt HAYSTACK NEEDLE LABEL
  if printf '%s' "$1" | grep -qF -- "$2"; then _fail "$3 (unexpected '$2' in: $1)"; else _pass "$3"; fi
}
ok(){   # ok "SHELL-EXPR" LABEL   (expr already expanded by caller)
  if eval "$1" >/dev/null 2>&1; then _pass "$2"; else _fail "$2 [$1]"; fi
}

report(){
  # A case that reaches report() having run ZERO assertions is a failure, not a pass —
  # otherwise a body that silently short-circuits would go green while testing nothing.
  if [ "$((T_PASS + T_FAIL))" -eq 0 ]; then
    echo "  -- 0 passed, 0 failed -- FAIL: case ran no assertions"; return 1
  fi
  echo "  -- $T_PASS passed, $T_FAIL failed --"; [ "$T_FAIL" -eq 0 ]
}
