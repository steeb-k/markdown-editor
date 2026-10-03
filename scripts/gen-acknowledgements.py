#!/usr/bin/env python3
"""Regenerates apps/macos/Resources/Acknowledgements.md: every third-party component that ships in
the app, with its license and copyright notice.

    scripts/gen-acknowledgements.py            write the file
    scripts/gen-acknowledgements.py --check    exit 1 if the file on disk is not what this would write

What is listed comes from the build, not from memory:

* Rust crates: `cargo metadata` for both macOS targets, followed from `markdown-ffi` along normal
  (not build, not dev) dependencies and without entering procedural-macro crates, whose code runs
  in the compiler and never reaches the binary. The result is an upper bound of what is linked in.
  Each crate's own LICENSE/COPYING/NOTICE files are read from the source cargo downloaded.
* The syntax definitions `two-face` embeds: its own acknowledgement data, by way of the
  `syntax_licenses` example of markdown-core.
* The bundled writing fonts: the OFL text shipped beside them (apps/macos/Resources/Fonts/OFL-LICENSE.md).
* `EXTRAS`: anything else that ships with a notice (the Fira Mono outlines in the app icon), each
  with its license text in scripts/licenses.

Needs `cargo` (rustup's) and the crates already fetched (`cargo fetch`). The output is deterministic.
"""
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "apps/macos/Resources/Acknowledgements.md")
TARGETS = ["aarch64-apple-darwin", "x86_64-apple-darwin"]
ROOT_PACKAGE = "markdown-ffi"
OWN = {"markdown-ffi", "markdown-core"}
# Other things that ship and carry a notice, listed under "Fonts" after the writing fonts:
# (heading, what it is and where it is used, the license text kept in this repository).
EXTRAS = [
    ("Fira Mono (in the app icon)",
     "The \"#m\" of the app icon is drawn from Fira Mono Bold (https://github.com/mozilla/Fira), converted to\n"
     "outlines; the outlines ship inside the icon. Fira Mono is used under the SIL Open Font License, Version 1.1:",
     "scripts/licenses/Fira-OFL.txt"),
]
LICENSE_FILE = re.compile(r"^(licen[cs]e|copying|notice|unlicense|copyright)([-_.].*)?$", re.I)

env = dict(os.environ)
env["PATH"] = os.path.expanduser("~/.cargo/bin") + os.pathsep + env.get("PATH", "")


def run(*args):
    return subprocess.run(args, cwd=ROOT, env=env, check=True, capture_output=True, text=True).stdout


def shipped_packages():
    found = {}
    for target in TARGETS:
        meta = json.loads(run("cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", target))
        packages = {p["id"]: p for p in meta["packages"]}
        nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
        root = next(i for i, p in packages.items() if p["name"] == ROOT_PACKAGE)

        def is_proc_macro(p):
            return any("proc-macro" in t["kind"] for t in p["targets"])

        stack, seen = [root], set()
        while stack:
            pid = stack.pop()
            if pid in seen:
                continue
            seen.add(pid)
            for dep in nodes[pid]["deps"]:
                # Normal dependencies only: `kind` null. (build and dev are other values.)
                if not any(k["kind"] is None for k in dep["dep_kinds"]):
                    continue
                p = packages[dep["pkg"]]
                if is_proc_macro(p):
                    continue
                stack.append(dep["pkg"])
        for pid in seen:
            p = packages[pid]
            if p["name"] in OWN:
                continue
            found[(p["name"], p["version"])] = p
    return [found[k] for k in sorted(found)]


def license_files(package):
    folder = os.path.dirname(package["manifest_path"])
    out = []
    for name in sorted(os.listdir(folder)):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and LICENSE_FILE.match(name):
            out.append(path)
    # A few crates keep them in a subfolder.
    for sub in ("licenses", "LICENSES", "license"):
        d = os.path.join(folder, sub)
        if os.path.isdir(d):
            out += [os.path.join(d, n) for n in sorted(os.listdir(d)) if os.path.isfile(os.path.join(d, n))]
    return out


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().replace("\r\n", "\n")


def split_copyright(text):
    """(copyright lines, the text without them): the permission text is printed once for all crates
    that share it, their copyright lines are listed with each."""
    lines, rest = [], []
    for line in text.split("\n"):
        # A real notice: "Copyright (c) ...", "Copyright 2015 ...", "(c) 2020 ...", "© 2020 ...". Not the
        # Apache appendix's template ("Copyright [yyyy] [name of copyright owner]") and not a sentence
        # of a license that happens to start with the word.
        if re.match(r"^\s*(copyright\s*(\(c\)|©|\d)|\(c\)\s*\d|©\s*\d)", line, re.I) and not re.search(r"yyyy", line, re.I):
            lines.append(line.strip())
        else:
            rest.append(line)
    body = "\n".join(rest).strip("\n")
    body = re.sub(r"\n{3,}", "\n\n", body)
    return lines, body


def fence(text):
    ticks = "````" if "```" in text else "```"
    return f"{ticks}text\n{text.rstrip()}\n{ticks}"


def main():
    check = "--check" in sys.argv
    packages = shipped_packages()
    bodies = {}      # sha -> (title, text)
    entries = []
    missing = []
    for p in packages:
        files = license_files(p)
        copyrights, refs = [], []
        for path in files:
            lines, body = split_copyright(read(path))
            copyrights += [l for l in lines if l not in copyrights]
            if not body.strip():
                continue
            key = hashlib.sha256(body.encode()).hexdigest()[:10]
            title = os.path.basename(path) if not body.lstrip().startswith(("MIT License", "Apache License")) else body.lstrip().split("\n")[0].strip()
            bodies.setdefault(key, (title, body))
            if key not in refs:
                refs.append(key)
        if not refs:
            # The crate ships no license file: the standard text for its SPDX id, kept in scripts/licenses.
            spdx = (p.get("license") or "").strip()
            fallback = os.path.join(ROOT, "scripts/licenses", spdx + ".txt")
            if re.fullmatch(r"[A-Za-z0-9.+-]+", spdx) and os.path.exists(fallback):
                _, body = split_copyright(read(fallback))
                key = hashlib.sha256(body.encode()).hexdigest()[:10]
                bodies.setdefault(key, (spdx, body))
                refs.append(key)
        if not refs:
            missing.append(f"{p['name']} {p['version']}")
        entries.append((p, copyrights, refs))

    names = {k: f"text {i + 1}" for i, k in enumerate(sorted(bodies, key=lambda k: (bodies[k][0], k)))}
    out = []
    w = out.append
    w("# Acknowledgements\n")
    w("This app is made with the work of others. Each component below is listed with its license and\n"
      "copyright notice; the full license texts follow the list.\n")
    w("This file is generated by `scripts/gen-acknowledgements.py` from the dependency graph of the\n"
      "build. Do not edit it by hand.\n")

    w("## Fonts\n")
    w("### the bundled Mono, Duo and Quattro faces\n")
    w("The writing fonts bundled with the app are Mono S, Duo S and Quattro S\n"
      ", used under the SIL Open Font License, Version 1.1:\n")
    w(fence(read(os.path.join(ROOT, "apps/macos/Resources/Fonts/OFL-LICENSE.md")).strip()) + "\n")
    for title, intro, path in EXTRAS:
        w(f"### {title}\n")
        w(intro + "\n")
        w(fence(read(os.path.join(ROOT, path)).strip()) + "\n")

    w("## Syntax highlighting definitions\n")
    w("Fenced code in the preview and in exported PDFs is highlighted by `syntect` with the syntax\n"
      "definitions curated by `bat` and packaged by `two-face`. They come from many authors under their own\n"
      "licenses; those definitions whose licenses require acknowledgement are listed here with their notices.\n"
      "Definitions from Sublime Text's default packages are used under Sublime HQ's permissive license\n"
      "(\"Permission to copy, use, modify, sell and distribute this software is granted. This software is\n"
      "provided \"as is\" without express or implied warranty, and with no claim as to its suitability for any\n"
      "purpose.\"). `bat` is copyright (c) 2018-2021 bat-developers (https://github.com/sharkdp/bat), and\n"
      "`two-face` is by CosmicHorrorDev and Harper (https://codeberg.org/CosmicHarper/two-face), both under\n"
      "the MIT or Apache-2.0 license.\n")
    syntax = run("cargo", "run", "-q", "-p", "markdown-core", "--example", "syntax_licenses")
    w(syntax.strip() + "\n")

    w("## Rust libraries\n")
    w(f"The editor's core is written in Rust and compiled into the app together with these {len(entries)} libraries.\n"
      "Where a library offers a choice of licenses, either may be used; both are listed.\n")
    for p, copyrights, refs in entries:
        w(f"### {p['name']} {p['version']}\n")
        w(f"License: {p.get('license') or 'see the license text'}" + (f" · {p['repository']}" if p.get("repository") else "") + "\n")
        if copyrights:
            w("\n".join(f"- {c}" for c in copyrights[:8]) + "\n")
        if refs:
            w("Text: " + ", ".join(names[r] for r in refs) + "\n")
        else:
            w("(No license text is available for this library; it is used under the license named above.)\n")

    w("## License texts\n")
    w("Where a text has a copyright line, the line is given with the library above, and the rest of the text here.\n")
    for key in sorted(bodies, key=lambda k: names[k]):
        title, body = bodies[key]
        users = [f"{p['name']} {p['version']}" for p, _, refs in entries if key in refs]
        w(f"### {names[key]}: {title}\n")
        w("Used by: " + ", ".join(users) + "\n")
        w(fence(body) + "\n")

    text = "\n".join(out)
    if missing:
        print("note: no license file shipped by: " + ", ".join(missing), file=sys.stderr)
    if check:
        try:
            current = open(OUT, encoding="utf-8").read()
        except FileNotFoundError:
            current = ""
        if current != text:
            print("Acknowledgements.md is out of date: run scripts/gen-acknowledgements.py", file=sys.stderr)
            sys.exit(1)
        print("Acknowledgements.md is up to date")
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {OUT}: {len(entries)} libraries, {len(bodies)} license texts, {len(text) // 1024} KB")


if __name__ == "__main__":
    main()
