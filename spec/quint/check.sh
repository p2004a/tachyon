#!/usr/bin/env bash
# Runs every check declared in the .qnt files of this directory.
# Directives, one per line, anywhere in a file:
#   // @test main=<module>                       -> quint test
#   // @inv  main=<module> inv=<expr> [steps=N] [samples=N]   -> quint run, must hold
#   // @witness main=<module> inv=<expr> [steps=N] [samples=N] -> quint run, must be VIOLATED
#   // @verify main=<module> inv=<expr> steps=N  -> quint verify (Apalache); only with VERIFY=1
# Usage: ./check.sh [file.qnt ...]
set -uo pipefail
cd "$(dirname "$0")"
files=("$@"); [ ${#files[@]} -eq 0 ] && files=(*.qnt)
fail=0
kv() { sed -n "s/.*\b$1=\([^ ]*\).*/\1/p" <<<"$2"; }
for f in "${files[@]}"; do
  quint typecheck "$f" >/dev/null 2>&1 || { echo "FAIL typecheck $f"; quint typecheck "$f" 2>&1 | head -20; fail=1; continue; }
  echo "ok   typecheck $f"
  while IFS= read -r line; do
    kind=$(sed -n 's/.*\/\/ @\([a-z]*\) .*/\1/p' <<<"$line")
    main=$(kv main "$line"); inv=$(kv inv "$line")
    steps=$(kv steps "$line"); steps=${steps:-25}
    samples=$(kv samples "$line"); samples=${samples:-10000}
    case "$kind" in
      test)
        if quint test --main="$main" "$f" >/tmp/qc.$$ 2>&1; then echo "ok   test $f:$main"; else echo "FAIL test $f:$main"; tail -30 /tmp/qc.$$; fail=1; fi ;;
      inv)
        if quint run --main="$main" --invariant="$inv" --max-steps="$steps" --max-samples="$samples" "$f" >/tmp/qc.$$ 2>&1; then echo "ok   inv $f:$main $inv"; else echo "FAIL inv $f:$main $inv"; tail -40 /tmp/qc.$$; fail=1; fi ;;
      witness)
        if quint run --main="$main" --invariant="$inv" --max-steps="$steps" --max-samples="$samples" "$f" >/tmp/qc.$$ 2>&1; then echo "FAIL witness not reached $f:$main $inv"; fail=1; else
          if grep -q "Invariant violated" /tmp/qc.$$; then echo "ok   witness $f:$main $inv"; else echo "FAIL witness error $f:$main"; tail -20 /tmp/qc.$$; fail=1; fi; fi ;;
      verify)
        [ "${VERIFY:-0}" = 1 ] || continue
        if quint verify --main="$main" --invariant="$inv" --max-steps="$steps" "$f" >/tmp/qc.$$ 2>&1; then echo "ok   verify $f:$main $inv"; else echo "FAIL verify $f:$main $inv"; tail -30 /tmp/qc.$$; fail=1; fi ;;
    esac
  done < <(grep -E '^\s*// @(test|inv|witness|verify) ' "$f")
done
rm -f /tmp/qc.$$
exit $fail
