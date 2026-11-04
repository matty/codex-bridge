#!/usr/bin/env bash
# smoke.sh — guards the two bugs that shipped in 1.1.1 and made the plugin unusable.
# No framework, no network, no Codex quota: run it before every release.
#
#   bash test/smoke.sh
#
# Exit 0 all passed, 1 otherwise.

set -uo pipefail
BIN="$(cd "$(dirname "$0")/../bin" && pwd)"
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=1; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "syntax"
for f in "$BIN"/codex-imagegen "$BIN"/codex-run; do
  check "$(basename "$f") parses" "bash -n '$f' 2>/dev/null"
done

# Regression 1 — `codex login status` writes to stderr. A check that pipes it with
# 2>/dev/null greps an empty string and always reports "not logged in", which made
# every command fail for every user. Exit status is the reliable signal.
echo
echo "login precondition"
check "does not grep a stderr-only message through 2>/dev/null" \
  "! grep -q \"login status 2>/dev/null | grep\" '$BIN'/codex-imagegen '$BIN'/codex-run"

if command -v codex >/dev/null 2>&1; then
  EMPTY="$(mktemp -d)"
  # A logged-out CODEX_HOME must be rejected. Guards the inverse bug: `grep -i
  # 'logged in'` also matches "Not logged in", waving a logged-out user through.
  # Capture first: under `pipefail`, `wrapper | grep` would inherit the wrapper's
  # intentional exit 1 and report a false failure.
  OUT="$(CODEX_HOME="$EMPTY" "$BIN/codex-imagegen" "x" "$EMPTY/o.png" 2>&1)"
  if printf '%s' "$OUT" | grep -q 'not logged in'; then
    ok "logged-out CODEX_HOME is rejected"
  else
    bad "logged-out CODEX_HOME was NOT rejected"
  fi
  rm -rf "$EMPTY"
else
  echo "  skip codex CLI not installed"
fi

# Regression 2 — codex's `-i/--image <FILE>...` is variadic, so a bare trailing prompt
# is parsed as one more image filename. Codex then blocks reading the prompt from
# stdin and exits 1. The `--` separator is load-bearing; do not remove it.
echo
echo "prompt separator"
check "codex-imagegen passes the instruction after --" \
  "grep -q 'CMD+=(-- \"\\\$INSTRUCTION\")' '$BIN/codex-imagegen'"
check "codex-run passes the task after --" \
  "grep -q 'CMD+=(-- \"\\\$TASK\")' '$BIN/codex-run'"

echo
# Routing — every route resolves, bad routes and efforts are refused before Codex
# runs, and the Fast tier stays off no matter what config.toml says.
echo "routing"
check "routes.sh parses" "bash -n '$BIN/../lib/routes.sh' 2>/dev/null"
# shellcheck source=../lib/routes.sh
. "$BIN/../lib/routes.sh"
for r in $ROUTE_NAMES; do
  ROUTED="$(route_lookup "$r")"
  check "route '$r' resolves to a model and a valid effort" \
    "[ -n '${ROUTED% *}' ] && valid_effort '${ROUTED#* }'"
done
# Capture first, as above: the wrappers' intentional exit 1 trips `pipefail`.
OUT="$("$BIN/codex-run" -R nope x 2>&1)"
check "unknown route is refused" "printf '%s' \"\$OUT\" | grep -q 'unknown route'"
OUT="$("$BIN/codex-run" -e fast x 2>&1)"
check "invalid effort is refused" "printf '%s' \"\$OUT\" | grep -q 'invalid effort'"
check "both wrappers pin the default service tier" \
  "grep -q 'SERVICE_TIER_ARGS' '$BIN/codex-run' && grep -q 'SERVICE_TIER_ARGS' '$BIN/codex-imagegen'"
check "no wrapper asks for the priority tier" \
  "! grep -q 'service_tier=\"priority\"' '$BIN/codex-run' '$BIN/codex-imagegen' '$BIN/../lib/routes.sh'"

echo
# Stuck and swapped runs — found generating a real batch on codex-cli 0.164.0. These
# run against a fake codex, so they need no login and spend no quota.
echo "image runs (fake codex)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/bin" "$TMP/out"
cat >"$TMP/bin/codex" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = login ] && exit 0
home="$CODEX_HOME"
printf '%s\n' "$*" >"$home/args.txt"
[ "$FAKE_MODE" = silent ] && sleep 30
cat >/dev/null   # blocks for as long as the wrapper leaves stdin open
echo '{"type":"thread.started","thread_id":"own"}'
if [ "$FAKE_MODE" = noimage ]; then echo boom; exit 1; fi
[ "$FAKE_MODE" = hang ] && sleep 30
png() { printf '\211PNG\r\n\032\n%s' "$1"; printf 'IEND\256B`\202'; }
param='num_last_images_to_include:1'
[ "$FAKE_MODE" = dropref ] && param='prompt:x'
if [ "$FAKE_MODE" != nolog ]; then
  mkdir -p "$home/sessions/2026/11/04"
  printf '{"payload":{"type":"custom_tool_call","input":"tools.image_gen__imagegen({%s})"}}\n' "$param" \
    >"$home/sessions/2026/11/04/rollout-t-own.jsonl"
fi
mkdir -p "$home/generated_images/own" "$home/generated_images/other"
png own >"$home/generated_images/own/exec-1.png"
# Another run's picture, and the newest file in the shared folder.
sleep 1
png decoy >"$home/generated_images/other/exec-2.png"
[ "$FAKE_MODE" = retry ] && sleep 30
exit 0
FAKE
chmod +x "$TMP/bin/codex"

# fake <mode> <args...> — fresh CODEX_HOME each time; sets RC and OUT.
fake() {
  local mode="$1"; shift
  rm -rf "$TMP/home"; mkdir -p "$TMP/home"
  OUT="$(FAKE_MODE="$mode" CODEX_HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$BIN/codex-imagegen" "$@" 2>&1)"
  RC=$?
}

# Writes the reference as a byte string; the fake never reads it.
printf 'ref' >"$TMP/ref.jpg"

rm -f "$TMP/out/a.png"
fake ok "p" "$TMP/out/a.png" </dev/null
check "saves and exits 0" "[ $RC -eq 0 ] && [ -s '$TMP/out/a.png' ]"
check "takes its own session's image, not the newest in the shared folder" "grep -q own '$TMP/out/a.png' && ! grep -q decoy '$TMP/out/a.png'"
check "tells codex not to save the image" "grep -q 'Do not save' '$BIN/codex-imagegen'"

S="$(date +%s)"
fake ok "p" "$TMP/out/b.png" < <(sleep 15)
check "does not wait on the caller's open stdin" "[ $RC -eq 0 ] && [ $(( $(date +%s) - S )) -lt 12 ]"

S="$(date +%s)"
fake retry "p" "$TMP/out/c.png" </dev/null
check "stops codex at the first image" "[ $RC -eq 0 ] && [ $(( $(date +%s) - S )) -lt 20 ]"

fake silent "p" "$TMP/out/d.png" --start-timeout 1 </dev/null
check "no session exits 124" "[ $RC -eq 124 ]"

fake hang "p" "$TMP/out/e.png" --timeout 1 </dev/null
check "no image in time exits 124" "[ $RC -eq 124 ]"

printf 'old' >"$TMP/out/f.png"
fake noimage "p" "$TMP/out/f.png" </dev/null
check "a failed run exits 2 and shows codex's output" "[ $RC -eq 2 ] && printf '%s' \"\$OUT\" | grep -q boom"
check "a failed run never passes off the old file as new" "[ \"\$(cat '$TMP/out/f.png')\" = old ]"

fake ok "p" "$TMP/out/g.png" --ref "$TMP/ref.jpg" </dev/null
check "an edit names the reference parameter and saves" "[ $RC -eq 0 ] && grep -q 'num_last_images_to_include:1' '$TMP/home/args.txt'"

rm -f "$TMP/out/h.png"
fake dropref "p" "$TMP/out/h.png" --ref "$TMP/ref.jpg" </dev/null
check "a dropped reference exits 3 and saves nothing" "[ $RC -eq 3 ] && [ ! -e '$TMP/out/h.png' ]"

fake nolog "p" "$TMP/out/i.png" --ref "$TMP/ref.jpg" </dev/null
check "a missing session log warns and saves" "[ $RC -eq 0 ] && printf '%s' \"\$OUT\" | grep -q 'could not find the image call'"

printf 'src' >"$TMP/out/j.png"
fake ok "p" "$TMP/out/j.png" --ref "$TMP/out/j.png" </dev/null
check "refuses to overwrite its own reference" "[ $RC -eq 1 ] && [ \"\$(cat '$TMP/out/j.png')\" = src ]"

check "codex-run closes stdin on both code paths" "[ \"\$(grep -c 'LOG_FILE\" 2>&1 </dev/null' '$BIN/codex-run')\" -eq 2 ]"
rm -rf "$TMP"

echo
if [ "$FAIL" -eq 0 ]; then echo "all passed"; else echo "FAILURES"; fi
exit "$FAIL"
