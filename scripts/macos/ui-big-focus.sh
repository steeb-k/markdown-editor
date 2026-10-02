#!/bin/bash
# 1 MB of dense Markdown: main-thread cost per keystroke, per caret move and per arrow key with
# focus mode and syntax highlighting off and on, in Source and Live mode. Every configuration
# runs in its own process on a freshly opened document: typing slows down in a long session
# whatever is switched on (the polish-list item in PLAN.md), which would confound a comparison.
#
#   scripts/macos/ui-big-focus.sh            # release build with the harness, then 8 runs
#   SKIP_BUILD=1 scripts/macos/ui-big-focus.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  "$ROOT/scripts/macos/bundle.sh" --release --ui-script >"$ROOT/build/ui-script-build.log" 2>&1
fi
for mode in source live; do
  for config in off focus syntax focus+syntax; do
    focus=false; syntax=false
    case "$config" in focus) focus=true ;; syntax) syntax=true ;; focus+syntax) focus=true; syntax=true ;; esac
    cat >"$TMP/$mode-$config.json" <<JSON
[
 {"setting": {"theme": "light", "fontChoice": "iaQuattro", "spellCheck": false, "showFormattingToolbar": true}},
 {"openGenerated": {"from": "scripts/macos/ui/fixtures/dense.md", "minLength": 1000000}},
 {"resize": [900, 820]},
 {"viewMode": "$mode"}, {"waitStyled": 180}, {"wait": 0.5},
 {"focus": {"on": $focus, "scope": "sentence"}}, {"syntax": {"on": $syntax}},
 {"selectText": "The end.", "offset": 8}, {"waitSyntax": 120}, {"wait": 0.5},
 {"log": "--- $mode mode, $config"},
 {"measureTyping": {"count": 150, "interval": 0.06}}, {"waitStyled": 60}, {"waitSyntax": 120},
 {"measureCaret": {"count": 200, "stride": 97}}, {"wait": 0.3}, {"waitSyntax": 120},
 {"selectText": "The end.", "offset": 8},
 {"measureKeys": {"count": 200, "command": "moveRight:"}},
 {"assert": {"coreMatchesText": true, "overlayStats": true}}
]
JSON
    SKIP_BUILD=1 RELEASE=1 "$ROOT/scripts/macos/ui-script.sh" "$TMP/$mode-$config.json" "$ROOT/build/ui/big-focus/$mode-$config" 2>&1 \
      | python3 -c '
import sys, json
for line in sys.stdin:
    try: d = json.loads(line.replace("[ui-script] ", ""))
    except ValueError: continue
    if "log" in d: print(d["log"])
    for k, label in (("measureTyping", "typing"), ("measureCaret", "caret"), ("measureKeys", "arrow")):
        if k in d:
            m = d[k]
            print("  %-7s mean %.2f ms   p50 %.2f   p99 %.2f   max %.1f" % (label, m.get("mean_ms", 0), m["p50_ms"], m["p99_ms"], m["max_ms"]))
'
  done
done
