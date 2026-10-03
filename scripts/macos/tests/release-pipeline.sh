#!/usr/bin/env bash
# Tests scripts/macos/release.sh's control flow without Apple: nothing is signed with a real identity and
# nothing is sent to the notary service. The repository (the working tree as it is, uncommitted changes
# included) is copied into a folder whose path has spaces, made a fresh one-commit git repository, and
# release.sh is run there from another directory:
#
#   - a dry run of a clean tree, which builds the universal release app, verifies it and makes the image;
#   - a dirty tree (refused; then accepted with --allow-dirty), a shallow clone, a missing, ambiguous or
#     non-Developer-ID identity: each refused before anything is built;
#   - the real (non-dry) path with stand-ins for codesign, security, xcrun and spctl on PATH
#     (scripts/macos/tests/stubs): a fake identity that signs ad-hoc, and a notary service that answers
#     Accepted, Invalid with exit status 0, malformed or empty output, an error, "In Progress" when the
#     wait runs out, or never answers; a stapler that fails; Gatekeeper rejecting the image, or
#     accepting it without its notarization. Only Accepted plus a notarized assessment may exit 0, a
#     staple may only follow Accepted, and no disk image may be left mounted.
#
#   scripts/macos/tests/release-pipeline.sh          (about 15 minutes: one universal release build)
#   KEEP=1 scripts/macos/tests/release-pipeline.sh   keep the work folder (its path is printed)
#
# Exits non-zero if any case fails; prints one line per check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STUB_SRC="$ROOT/scripts/macos/tests/stubs"
# (Normalised: TMPDIR usually ends in a slash, and release.sh names its paths as `pwd` does, so a
# "T//release" here never matched the "T/release" it records.)
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/release pipeline test.XXXXXX")" && pwd)"
COPY="$WORK/markdown editor (copy)"
STUBS="$WORK/stub bin"
LOGS="$WORK/logs"
mkdir -p "$COPY" "$STUBS" "$LOGS"
FAKE_ID="Developer ID Application: Test Stub (TESTSTUB00)"
FAILURES=0

mounted_under_work() { hdiutil info | grep -F "$WORK" || true; }
cleanup() {
  # Anything still mounted from the work folder is a failure of the script under test; detach it anyway.
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    hdiutil detach "$(printf '%s' "$m" | awk -F'\t' '{print $NF}')" -force >/dev/null 2>&1 || true
  done < <(hdiutil info | awk -F'\t' -v w="$WORK" 'index($NF, w) == 1 {print}')
  if [ "${KEEP:-0}" = 1 ]; then echo "work folder kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

pass() { printf '  ok    %s\n' "$*"; }
failed() { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
check() { # <description> <command...>
  local what="$1"; shift
  if "$@"; then pass "$what"; else failed "$what"; fi
}
contains() { grep -q -F -- "$2" "$1"; }
lacks() { ! grep -q -F -- "$2" "$1"; }

for s in xcrun security spctl codesign; do cp "$STUB_SRC/$s" "$STUBS/$s"; chmod +x "$STUBS/$s"; done

# Runs release.sh in the copy (or $REPO) from the work folder (not the repository), with the stubs on
# PATH. Output in $LOGS/<name>.log, the stubs' record of calls in $LOGS/<name>.calls, exit status in
# $STATUS, duration in $SECONDS_TAKEN. Leading VAR=value arguments are added to its environment.
run_release() { # <name> [VAR=value...] [release.sh options...]
  local name="$1"; shift
  local -a extra=()
  while [ $# -gt 0 ] && [[ "$1" == [A-Z_]*=* ]]; do extra+=("$1"); shift; done
  local repo="${REPO:-$COPY}"
  : > "$LOGS/$name.calls"
  local t0=$SECONDS
  STATUS=0
  (cd "$WORK" && env PATH="$STUBS:$PATH" STUB_CALLS="$LOGS/$name.calls" STUB_IDENTITY="$FAKE_ID" \
      ${extra[@]+"${extra[@]}"} "$repo/scripts/macos/release.sh" "$@") > "$LOGS/$name.log" 2>&1 || STATUS=$?
  SECONDS_TAKEN=$((SECONDS - t0))
  printf '\n[%s] release.sh %s -> exit %s in %ss\n' "$name" "$*" "$STATUS" "$SECONDS_TAKEN"
}
show_tail() { tail -n "${2:-15}" "$LOGS/$1.log" | sed 's/^/        | /'; }

echo "==> copying the working tree to $COPY"
# (Files deleted in the working tree but not yet in a commit are still listed by git: left out.)
(cd "$ROOT" && git ls-files -z -co --exclude-standard | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
  | tar --null -T - -cf -) | tar -xf - -C "$COPY"
# The build products are cloned (copy-on-write, no space used) so that cargo's dependencies need not be
# compiled again; the copy's own crates and the Swift package are rebuilt because their paths differ.
if [ -d "$ROOT/target" ]; then cp -cR "$ROOT/target" "$COPY/target" 2>/dev/null || true; fi
(cd "$COPY" && git init -q && git add -A && git -c user.name=test -c user.email=test@invalid commit -q -m "snapshot for the release pipeline test")
echo "    $(cd "$COPY" && git rev-list --count HEAD) commit, $(cd "$COPY" && git ls-files | wc -l | tr -d ' ') files"

# --- refusals before anything is built -------------------------------------------------------------
echo
echo "==> refusals"
touch "$COPY/uncommitted file.txt"
run_release dirty --dry-run --skip-tests
check "a dirty tree is refused" [ "$STATUS" != 0 ]
check "  ... saying so" contains "$LOGS/dirty.log" "the working tree is not clean"
check "  ... before building" lacks "$LOGS/dirty.log" "universal release bundle"
rm "$COPY/uncommitted file.txt"

unset CODESIGN_IDENTITY NOTARIZE_PROFILE
run_release no-identity STUB_IDENTITIES=none --skip-tests
check "no identity: refused" [ "$STATUS" != 0 ]
check "  ... naming the variable" contains "$LOGS/no-identity.log" "CODESIGN_IDENTITY is not set"

run_release missing-identity STUB_IDENTITIES=none CODESIGN_IDENTITY="$FAKE_ID" --skip-tests
check "an identity the keychain lacks: refused" [ "$STATUS" != 0 ]
check "  ... saying so" contains "$LOGS/missing-identity.log" "no valid code-signing identity"
check "  ... before building" lacks "$LOGS/missing-identity.log" "universal release bundle"

run_release ambiguous-identity STUB_IDENTITIES="$FAKE_ID
$FAKE_ID" CODESIGN_IDENTITY="$FAKE_ID" --skip-tests
check "a name two certificates share: refused" [ "$STATUS" != 0 ]
check "  ... asking for the hash" contains "$LOGS/ambiguous-identity.log" "SHA-1 hash"

run_release wrong-kind STUB_IDENTITIES="Apple Development: Test Stub (TESTSTUB00)" \
  CODESIGN_IDENTITY="Apple Development: Test Stub (TESTSTUB00)" --skip-tests
check "an identity that is not Developer ID Application: refused" [ "$STATUS" != 0 ]
check "  ... saying so" contains "$LOGS/wrong-kind.log" "not a Developer ID Application identity"

git clone -q --depth 1 "file://$COPY" "$WORK/shallow clone" 2>/dev/null
REPO="$WORK/shallow clone" run_release shallow STUB_IDENTITIES="$FAKE_ID" CODESIGN_IDENTITY="$FAKE_ID" --skip-tests
check "a shallow clone (a wrong build number): refused" [ "$STATUS" != 0 ]
check "  ... saying so" contains "$LOGS/shallow.log" "shallow clone"
rm -rf "$WORK/shallow clone"

# --- the dry run ------------------------------------------------------------------------------------
echo
echo "==> the dry run (a universal release build; minutes)"
# Whatever the environment holds, a dry run neither signs with it nor contacts the notary service.
run_release dry-run STUB_IDENTITIES=none CODESIGN_IDENTITY="$FAKE_ID" NOTARIZE_PROFILE=should-be-ignored --dry-run --skip-tests
show_tail dry-run 14
check "the dry run of a clean tree succeeds" [ "$STATUS" = 0 ]
check "  ... says it is a dry run" contains "$LOGS/dry-run.log" "DRY RUN"
check "  ... ignores NOTARIZE_PROFILE, and says so" contains "$LOGS/dry-run.log" "NOTARIZE_PROFILE is set and was ignored"
check "  ... contacts no notary service and staples nothing" [ ! -s "$LOGS/dry-run.calls" ]
check "  ... verifies the bundle" contains "$LOGS/dry-run.log" "==> bundle OK"
check "  ... reports a clean tree" contains "$LOGS/dry-run.log" "working tree   clean"
APP="$COPY/build/Markdown.app"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
DMG="$COPY/build/Markdown-$VERSION.dmg"
check "  ... writes the disk image" [ -s "$DMG" ]
check "  ... the build number is the commit count (1 here)" [ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = 1 ]
check "  ... the app is ad-hoc signed" sh -c "codesign -dv '$APP' 2>&1 | grep -q 'Signature=adhoc'"
check "  ... leaves nothing mounted" [ -z "$(mounted_under_work)" ]

touch "$COPY/uncommitted file.txt"
run_release dirty-allowed --dry-run --skip-tests --allow-dirty
check "--allow-dirty builds a dirty tree" [ "$STATUS" = 0 ]
check "  ... and the summary says DIRTY" contains "$LOGS/dirty-allowed.log" "DIRTY (--allow-dirty)"
rm "$COPY/uncommitted file.txt"

# --- the real path, with a notary service that answers as told ----------------------------------------
echo
echo "==> the real path, with stand-ins for the identity and the notary service"
notary_case() { # <name> <STUB_NOTARY> <expect: ok|fail> [VAR=value...]
  local name="$1" notary="$2" expect="$3"; shift 3
  run_release "$name" STUB_IDENTITIES="$FAKE_ID" CODESIGN_IDENTITY="$FAKE_ID" NOTARIZE_PROFILE=test-profile \
    STUB_NOTARY="$notary" "$@" --skip-tests
  if [ "$expect" = ok ]; then
    check "$name: exits 0" [ "$STATUS" = 0 ]
  else
    check "$name: exits non-zero" [ "$STATUS" != 0 ]
    # (A staple follows an Accepted verdict; these cases fail later, at the staple or at Gatekeeper.)
    if [ "$notary" != accepted ]; then check "  ... and staples nothing" lacks "$LOGS/$name.calls" "stapler staple"; fi
  fi
  check "  ... leaves nothing mounted" [ -z "$(mounted_under_work)" ]
  if [ "$STATUS" != 0 ] || [ "$expect" != ok ]; then show_tail "$name" 6; fi
}

notary_case accepted accepted ok
check "  ... submits the disk image" contains "$LOGS/accepted.calls" "notarytool submit $DMG"
check "  ... with a timeout" contains "$LOGS/accepted.calls" "--timeout"
check "  ... staples and validates the image" sh -c "grep -q -F 'stapler staple $DMG' '$LOGS/accepted.calls' && grep -q -F 'stapler validate $DMG' '$LOGS/accepted.calls'"
check "  ... assesses the image and the app inside it" sh -c "grep -c '^spctl' '$LOGS/accepted.calls' | grep -qx 2"
check "  ... confirms the Developer ID signature" contains "$LOGS/accepted.log" "Developer ID, secure timestamp and hardened runtime: confirmed"
check "  ... reports notarized" contains "$LOGS/accepted.log" "notarized      yes"

notary_case invalid invalid fail
check "  ... says what the service answered" contains "$LOGS/invalid.log" "answered 'Invalid'"
check "  ... and prints the notary log" contains "$LOGS/invalid.calls" "notarytool log 0a1b2c3d"
notary_case malformed malformed fail
notary_case empty empty fail
check "  ... says nothing came back" contains "$LOGS/empty.log" "answered 'nothing'"
notary_case error error fail
check "  ... shows notarytool's error" contains "$LOGS/error.log" "Unable to authenticate"
notary_case in-progress in-progress fail
check "  ... says how to finish by hand" contains "$LOGS/in-progress.log" "xcrun notarytool wait 0a1b2c3d"
notary_case hang hang fail NOTARIZE_TIMEOUT=2 NOTARIZE_GRACE=3
check "  ... is stopped by the watchdog" contains "$LOGS/hang.log" "did not finish within 5 s"
notary_case staple-fails accepted fail STUB_STAPLE=fail
check "  ... and says the image is notarized" contains "$LOGS/staple-fails.log" "stapling failed; the image is notarized"
notary_case gatekeeper-rejects accepted fail STUB_SPCTL=rejected
check "  ... saying spctl rejected it" contains "$LOGS/gatekeeper-rejects.log" "spctl rejected the disk image"
notary_case not-notarized-source accepted fail STUB_SPCTL=developer-id
check "  ... an acceptance that is not a notarization is not enough" contains "$LOGS/not-notarized-source.log" "not as a notarized"

echo
if [ "$FAILURES" = 0 ]; then
  echo "release pipeline: all checks passed"
else
  echo "release pipeline: $FAILURES check(s) FAILED (logs: $LOGS; KEEP=1 keeps them)"
  exit 1
fi
