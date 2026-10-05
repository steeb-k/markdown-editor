#!/bin/bash
# 1 MB of dense Markdown: main-thread cost per keystroke, per caret move and per arrow key with
# focus mode and syntax highlighting off and on, and with everything on ("all": focus, syntax
# and about 3,300 authorship runs shown in colour), in Source and Live mode. Every configuration
# runs in its own process on a freshly opened document: typing slows down in a long session
# whatever is switched on (a polish item), which would confound a comparison.
#
#   scripts/macos/ui-big-focus.sh            # release build with the harness, then 10 runs
#   SKIP_BUILD=1 scripts/macos/ui-big-focus.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
UI_BUILD="${UI_BUILD:-$ROOT/build}"
export UI_BUILD
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  mkdir -p "$UI_BUILD"
  "$ROOT/scripts/macos/bundle.sh" --release --ui-script --out "$UI_BUILD" >"$UI_BUILD/ui-script-build.log" 2>&1
fi
for mode in source live; do
  for config in off focus-flat focus syntax focus+syntax all; do
    focus=false; syntax=false; centre=true; marks='{"log": "no marks"}'
    case "$config" in focus) focus=true ;; focus-flat) focus=true; centre=false ;; syntax) syntax=true ;; focus+syntax) focus=true; syntax=true ;;
      all) focus=true; syntax=true; marks='{"markEvery": {"stride": 300, "length": 100, "as": "ai"}}, {"authorshipDisplay": true}' ;; esac
    cat >"$TMP/$mode-$config.json" <<JSON
[
 {"setting": {"theme": "light", "fontChoice": "iaQuattro", "spellCheck": false, "showFormattingToolbar": true, "centreFocusedLine": $centre}},
 {"openGenerated": {"from": "scripts/macos/ui/fixtures/dense.md", "minLength": 1000000}},
 {"resize": [900, 820]},
 {"viewMode": "$mode"}, {"waitStyled": 180}, {"wait": 0.5},
 {"focus": {"on": $focus, "scope": "sentence"}}, {"syntax": {"on": $syntax}}, $marks,
 {"selectText": "The end.", "offset": 8}, {"waitSyntax": 120}, {"wait": 0.5},
 {"log": "--- $mode mode, $config"},
 {"measureTyping": {"count": 150, "interval": 0.06}}, {"waitStyled": 60}, {"waitSyntax": 120},
 {"measureCaret": {"count": 200, "stride": 97}}, {"wait": 0.3}, {"waitSyntax": 120},
 {"selectText": "The end.", "offset": 8},
 {"measureKeys": {"count": 200, "command": "moveRight:"}},
 {"assert": {"coreMatchesText": true, "overlayStats": true, "overlayConsistent": true}},
 {"measureSave": true}
]
JSON
    SKIP_BUILD=1 RELEASE=1 "$ROOT/scripts/macos/ui-script.sh" "$TMP/$mode-$config.json" "$ROOT/build/ui/big-focus/$mode-$config" 2>&1 \
      | python3 -c '
import sys, json
for line in sys.stdin:
    try: d = json.loads(line.replace("[ui-script] ", ""))
    except ValueError: continue
    if "log" in d: print(d["log"])
    if "markEvery" in d: print("  runs:", d["runs"])
    if d.get("ok") is False: print("  FAILED:", d)
    for k, label in (("measureTyping", "typing"), ("measureCaret", "caret"), ("measureKeys", "arrow")):
        if k in d:
            m = d[k]
            print("  %-7s mean %.2f ms   p50 %.2f   p99 %.2f   max %.1f" % (label, m.get("mean_ms", 0), m["p50_ms"], m["p99_ms"], m["max_ms"]))
            if "mean_centre_ms" in m and (m.get("centre_slides") or m.get("centre_jumps") or m.get("centre_frames")):
                print("          centring: %.3f ms/key on the main thread (slides %d, jumps %d, frames %d, longest frame %.2f ms)" % (m["mean_centre_ms"], m["centre_slides"], m["centre_jumps"], m["centre_frames"], m["centre_longest_frame_ms"]))
    if "measureSave" in d and isinstance(d["measureSave"], dict):
        m = d["measureSave"]
        print("  save    total %.1f ms   longest main-thread gap %.1f ms   %d bytes   off main: %s" % (m["total_ms"], m["max_runloop_gap_ms"], m["bytes"], m["off_main"]))
'
  done
done
