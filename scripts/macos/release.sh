#!/usr/bin/env bash
# The one command that makes a release: tests, universal build, Developer ID signing, a signed
# disk image, notarization, stapling and the Gatekeeper checks.
#
#   CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)' NOTARIZE_PROFILE=notary \
#       scripts/macos/release.sh
#
#   scripts/macos/release.sh --dry-run --allow-dirty    everything except Developer ID signing and
#                                                       notarization (ad-hoc signed, nothing is sent
#                                                       anywhere); for trying the pipeline
#
# Options:
#   --dry-run       ad-hoc sign, never contact Apple, skip the Gatekeeper assessments (an ad-hoc
#                   build fails them by design). The output says so at every step.
#   --allow-dirty   build from a working tree with uncommitted changes (refused otherwise)
#   --skip-tests    do not run the Rust and Swift test suites first
#
# Environment:
#   CODESIGN_IDENTITY   the signing identity's common name, or its SHA-1 hash (required unless
#                       --dry-run); a name that matches two certificates is refused (use the hash)
#   NOTARIZE_PROFILE    a `xcrun notarytool store-credentials` profile name; without it the image is
#                       signed but not notarized, and the summary says so
#   NOTARIZE_TIMEOUT    seconds to wait for the notary service's verdict (default 7200); past it the
#                       script stops and prints how to finish by hand. A watchdog stops a notarytool
#                       that outlives its own timeout by NOTARIZE_GRACE seconds (default 120).
#
# Steps: clean-tree check; cargo test and swift test; universal release bundle (scripts/macos/bundle.sh)
# signed with the identity; verification of the bundle's contents, signature and hardened runtime;
# the disk image (scripts/macos/make-dmg.sh), signed; notarytool submit --wait and a check of the
# verdict (an Invalid verdict still exits 0, so the status is read from the JSON); on Accepted,
# stapler staple and validate, spctl on the image and on the app inside a read-only mount; a summary.
# Nothing secret is printed: the profile is only a name, the credentials stay in the keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.cargo/bin:$PATH"

DRY_RUN=0
ALLOW_DIRTY=0
SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "release: unknown option: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "release: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

if [ "$DRY_RUN" = 1 ]; then
  cat >&2 <<'EOF'

#############################################################################
#  DRY RUN: the app and the image are signed AD-HOC, not with a Developer   #
#  ID, and nothing is submitted to Apple. The result will NOT pass          #
#  Gatekeeper and must not be shipped.                                      #
#############################################################################
EOF
  # Whatever the environment holds, a dry run never signs with it or contacts the notary service.
  unset CODESIGN_IDENTITY
  NOTARIZE_PROFILE_WAS_SET="${NOTARIZE_PROFILE:+yes}"
  unset NOTARIZE_PROFILE
else
  [ -n "${CODESIGN_IDENTITY:-}" ] || die "CODESIGN_IDENTITY is not set (use --dry-run to try the pipeline without it)"
  # The valid identities, one per line: `  1) <SHA-1> "<common name>"`. The identity may be given by
  # name or by hash; a name shared by two certificates would make codesign stop with "ambiguous"
  # half-way through, so it is refused here, before anything is built.
  IDENTITIES="$(security find-identity -v -p codesigning 2>&1)" || die "security find-identity failed: $IDENTITIES"
  MATCHES="$(printf '%s\n' "$IDENTITIES" | awk -v id="$CODESIGN_IDENTITY" '
    $1 ~ /^[0-9]+\)$/ { name = $0; sub(/^[^"]*"/, "", name); sub(/"[^"]*$/, "", name);
                        if (name == id || toupper($2) == toupper(id)) n++ }
    END { print n + 0 }')"
  [ "$MATCHES" -ge 1 ] \
    || die "no valid code-signing identity named '$CODESIGN_IDENTITY' in the keychain (security find-identity -v -p codesigning)"
  [ "$MATCHES" -eq 1 ] \
    || die "'$CODESIGN_IDENTITY' names $MATCHES valid identities; set CODESIGN_IDENTITY to the SHA-1 hash of the one to use"
  case "$CODESIGN_IDENTITY" in
    *"Developer ID Application"*) ;;
    *) printf '%s\n' "$IDENTITIES" | grep -i -F "$CODESIGN_IDENTITY" | grep -q 'Developer ID Application' \
         || die "'$CODESIGN_IDENTITY' is not a Developer ID Application identity" ;;
  esac
  export CODESIGN_IDENTITY
fi

# --- 1. a clean tree, a whole history ------------------------------------------------------------
step "checking the working tree"
git rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout: the build number comes from its history"
# The build number (CFBundleVersion) is the number of commits; a shallow clone would make it small
# and a later release could carry a lower number than an earlier one.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo "   shallow clone: the build number will be wrong (dry run, so carrying on)" >&2
  else
    die "this is a shallow clone, so the build number (the commit count) would be wrong; run git fetch --unshallow"
  fi
fi
TREE_STATE="clean"
if [ -n "$(git status --porcelain)" ]; then
  TREE_STATE="DIRTY (--allow-dirty)"
  if [ "$ALLOW_DIRTY" = 1 ]; then
    echo "   the tree has uncommitted changes (--allow-dirty): this build cannot be reproduced from a commit" >&2
  else
    git status --short >&2
    die "the working tree is not clean; commit or stash, or pass --allow-dirty"
  fi
else
  echo "   clean: $(git rev-parse --short HEAD)"
fi

# --- 2. tests ----------------------------------------------------------------------------------
TESTS_STATE="passed"
if [ "$SKIP_TESTS" = 1 ]; then
  TESTS_STATE="NOT RUN (--skip-tests)"
  echo "   (--skip-tests: the test suites are NOT run)" >&2
else
  step "cargo test --workspace"
  cargo test --workspace
  step "swift test (debug core)"
  "$ROOT/scripts/build-core.sh"
  (cd "$ROOT/apps/macos" && swift test)
fi

# --- 2b. the notices that ship in the app are the dependencies' -----------------------------------
step "acknowledgements"
"$ROOT/scripts/gen-acknowledgements.py" --check

# --- 3. build, bundle, sign --------------------------------------------------------------------
step "universal release bundle"
"$ROOT/scripts/macos/bundle.sh" --release --universal
APP="$ROOT/build/Markdown.app"

# --- 4. verify ---------------------------------------------------------------------------------
step "verifying the bundle"
"$ROOT/scripts/macos/verify-bundle.sh" "$APP" --universal --no-harness
SIGDETAIL="$(codesign -dvv "$APP" 2>&1)"
if [ "$DRY_RUN" = 0 ]; then
  echo "$SIGDETAIL" | grep -q '^Authority=Developer ID Application' || die "the app is not signed with a Developer ID Application certificate"
  echo "$SIGDETAIL" | grep -q '^Timestamp=' || die "the app's signature carries no secure timestamp"
  echo "$SIGDETAIL" | grep -q 'flags=.*runtime' || die "the hardened runtime flag is not set"
  echo "$SIGDETAIL" | grep -q 'flags=.*adhoc' && die "the app is ad-hoc signed"
  echo "   Developer ID, secure timestamp and hardened runtime: confirmed"
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"

# --- 5. the disk image -------------------------------------------------------------------------
step "disk image"
DMG="$ROOT/build/Markdown-$VERSION.dmg"
"$ROOT/scripts/macos/make-dmg.sh" "$APP" "$DMG"
if [ "$DRY_RUN" = 0 ]; then
  DMGDETAIL="$(codesign -dvv "$DMG" 2>&1)" || die "the disk image is not signed: $DMGDETAIL"
  echo "$DMGDETAIL" | grep -q '^Authority=Developer ID Application' || die "the disk image is not signed with the Developer ID certificate"
  echo "$DMGDETAIL" | grep -q '^Timestamp=' || die "the disk image's signature carries no secure timestamp"
  echo "   disk image signed with the Developer ID, timestamped"
fi

# --- 6. notarize and staple --------------------------------------------------------------------
NOTARIZED="no"
SPCTL_DMG="not run"
SPCTL_APP="not run"
NOTARIZE_TIMEOUT="${NOTARIZE_TIMEOUT:-7200}"
NOTARIZE_GRACE="${NOTARIZE_GRACE:-120}"
case "$NOTARIZE_TIMEOUT$NOTARIZE_GRACE" in ''|*[!0-9]*) die "NOTARIZE_TIMEOUT and NOTARIZE_GRACE must be numbers of seconds" ;; esac
if [ "$DRY_RUN" = 1 ]; then
  step "notarization"
  echo "   dry run: nothing is submitted${NOTARIZE_PROFILE_WAS_SET:+ (NOTARIZE_PROFILE is set and was ignored)}" >&2
elif [ -z "${NOTARIZE_PROFILE:-}" ]; then
  step "notarization"
  echo "   WARNING: NOTARIZE_PROFILE is not set: the image is signed but NOT notarized, and Gatekeeper will" >&2
  echo "   refuse it on a Mac that downloaded it. Set NOTARIZE_PROFILE to a notarytool keychain profile." >&2
else
  step "notarizing (a few minutes; profile '$NOTARIZE_PROFILE')"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/markdown-release.XXXXXX")"
  MNT="$WORK/mnt"
  MOUNTED=0
  cleanup() {
    if [ "$MOUNTED" = 1 ]; then hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; fi
    # Never delete through a mount point that is still attached.
    if [ "$MOUNTED" = 0 ] || ! [ -d "$MNT/Markdown.app" ]; then rm -rf "$WORK"; fi
  }
  trap cleanup EXIT
  SUBMIT_STATUS=0
  # notarytool's own --timeout ends the wait; the watchdog is for a notarytool that hangs anyway
  # (a stuck upload, a keychain prompt nobody answers). Either way the submission's id, if one
  # was printed, says how to carry on by hand.
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait --timeout "$NOTARIZE_TIMEOUT" \
    --output-format json > "$WORK/submit.json" 2> "$WORK/submit.err" &
  NOTARY_PID=$!
  ( for _ in $(seq 1 $((NOTARIZE_TIMEOUT + NOTARIZE_GRACE))); do sleep 1; kill -0 "$NOTARY_PID" 2>/dev/null || exit 0; done
    echo "release: notarytool did not finish within $((NOTARIZE_TIMEOUT + NOTARIZE_GRACE)) s; stopping it" >&2
    kill -TERM "$NOTARY_PID" 2>/dev/null ) &
  WATCHDOG_PID=$!
  wait "$NOTARY_PID" || SUBMIT_STATUS=$?
  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  cat "$WORK/submit.json"
  if [ -s "$WORK/submit.err" ]; then cat "$WORK/submit.err" >&2; fi
  # `--wait` exits 0 for an Invalid verdict, so the exit status says nothing about the outcome:
  # the status field does. plutil reads JSON; python3 is the fallback if it says nothing.
  json_field() { # <field>
    local v
    v="$(plutil -extract "$1" raw -o - "$WORK/submit.json" 2>/dev/null || true)"
    if [ -z "$v" ]; then
      v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$WORK/submit.json" "$1" 2>/dev/null || true)"
    fi
    printf '%s' "$v"
  }
  SUBMISSION_ID="$(json_field id)"
  STATUS="$(json_field status)"
  if [ "$STATUS" != "Accepted" ]; then
    echo "release: the notary service answered '${STATUS:-nothing}' (notarytool exit status $SUBMIT_STATUS)" >&2
    if [ -n "$SUBMISSION_ID" ]; then
      case "$STATUS" in
        "In Progress"|"")
          # Still being processed (the wait ran out): nothing is wrong yet. Finish by hand.
          echo "release: the submission may still be in progress. To finish without building again:" >&2
          echo "release:   xcrun notarytool wait $SUBMISSION_ID --keychain-profile '$NOTARIZE_PROFILE'" >&2
          echo "release:   xcrun stapler staple '$DMG' && xcrun stapler validate '$DMG'" >&2
          echo "release:   spctl -a -t open --context context:primary-signature -vv '$DMG'" >&2 ;;
        *)
          echo "release: --- the notary log, which says why ---" >&2
          xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARIZE_PROFILE" >&2 || true ;;
      esac
    fi
    die "notarization did not succeed"
  fi
  echo "   notarization Accepted (submission $SUBMISSION_ID)"
  step "stapling"
  xcrun stapler staple "$DMG" || die "stapling failed; the image is notarized (submission $SUBMISSION_ID): retry with xcrun stapler staple '$DMG'"
  xcrun stapler validate "$DMG" || die "the stapled ticket does not validate"
  NOTARIZED="yes (submission $SUBMISSION_ID), stapled"

  step "Gatekeeper"
  # An exit status of 0 is not enough: the source must be the notarization, not some other rule.
  SPCTL_DMG="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1)" \
    || { echo "$SPCTL_DMG" >&2; die "spctl rejected the disk image"; }
  echo "$SPCTL_DMG"
  echo "$SPCTL_DMG" | grep -q 'source=Notarized Developer ID' || die "spctl accepted the disk image, but not as a notarized Developer ID image"
  mkdir -p "$MNT"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
  MOUNTED=1
  # The app inside the image is the app that was verified above.
  diff -r "$APP" "$MNT/Markdown.app" >/dev/null || die "the app inside the disk image differs from $APP"
  SPCTL_APP="$(spctl -a -t exec -vv "$MNT/Markdown.app" 2>&1)" \
    || { echo "$SPCTL_APP" >&2; die "spctl rejected the app inside the disk image"; }
  echo "$SPCTL_APP"
  echo "$SPCTL_APP" | grep -q 'source=Notarized Developer ID' || die "spctl accepted the app, but not as a notarized Developer ID app"
  hdiutil detach "$MNT" >/dev/null
  MOUNTED=0
fi

# --- 7. summary --------------------------------------------------------------------------------
step "summary"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
APP_SIZE="$(du -sh "$APP" | awk '{print $1}')"
DMG_SIZE="$(du -h "$DMG" | awk '{print $1}')"
echo "   version        $VERSION (build $BUILD_NUMBER, commit $(git rev-parse --short HEAD))"
echo "   working tree   $TREE_STATE"
echo "   tests          $TESTS_STATE"
echo "   app            $APP ($APP_SIZE)"
echo "   disk image     $DMG ($DMG_SIZE)"
echo "   sha-256        $SHA"
echo "   architectures  $(lipo -archs "$APP/Contents/MacOS/Markdown")"
echo "   signature      $(echo "$SIGDETAIL" | grep -E '^(Signature=|Authority=|TeamIdentifier=)' | head -2 | tr '\n' ' ')"
echo "   notarized      $NOTARIZED"
echo "   spctl (image)  $(echo "$SPCTL_DMG" | tr '\n' ' ')"
echo "   spctl (app)    $(echo "$SPCTL_APP" | tr '\n' ' ')"
if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "   DRY RUN: ad-hoc signed, not notarized, will not pass Gatekeeper. Do not ship this." >&2
fi
