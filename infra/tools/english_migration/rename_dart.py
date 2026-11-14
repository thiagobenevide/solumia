"""Whole-word rename of Dart identifiers, outside string literals and comments.

Usage:
  rename_dart.py MAP.txt FILE... [--apply]   rename with `old new` pairs (one per line, `#` comments)
  rename_dart.py --idents FILE...            list identifiers used in code (not in strings/comments)

Identifiers inside `$x` and `${...}` interpolations are renamed too. String text and comments are never
changed, so JSON keys and routes stay as they are. Names that come from other packages (e.g. `agent_core`)
must be left out of the map; `flutter analyze` shows any call site that still needs a manual fix.
"""

import re
import sys

IDENT = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
PLAIN_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def load_map(path):
    mapping = {}
    for line in open(path, encoding="utf-8"):
        if line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) == 2:
            mapping[parts[0]] = parts[1]
    return mapping


class Renamer:
    def __init__(self, src, mapping):
        self.src = src
        self.mapping = mapping
        self.i = 0
        self.out = []
        self.seen = set()

    def word(self, pattern):
        match = pattern.match(self.src, self.i)
        name = match.group(0)
        self.seen.add(name)
        self.out.append(self.mapping.get(name, name))
        self.i = match.end()

    def copy(self, size=1):
        self.out.append(self.src[self.i:self.i + size])
        self.i += size

    def code(self, stop_on_brace=False):
        depth = 0
        while self.i < len(self.src):
            char = self.src[self.i]
            pair = self.src[self.i:self.i + 2]
            if pair == "//":
                end = self.src.find("\n", self.i)
                if end < 0:
                    end = len(self.src)
                self.copy(end - self.i)
            elif pair == "/*":
                end = self.src.find("*/", self.i) + 2
                self.copy(end - self.i)
            elif char in "'\"":
                self.string(raw=False)
            elif char == "r" and self.src[self.i + 1:self.i + 2] in ("'", '"'):
                self.copy()
                self.string(raw=True)
            elif char.isalpha() or char == "_" or char == "$":
                self.word(IDENT)
            elif char == "{":
                depth += 1
                self.copy()
            elif char == "}":
                if stop_on_brace and depth == 0:
                    self.copy()
                    return
                depth -= 1
                self.copy()
            else:
                self.copy()

    def string(self, raw):
        quote = self.src[self.i]
        if self.src[self.i:self.i + 3] == quote * 3:
            quote = quote * 3
        self.copy(len(quote))
        while self.i < len(self.src):
            if self.src.startswith(quote, self.i):
                self.copy(len(quote))
                return
            char = self.src[self.i]
            following = self.src[self.i + 1:self.i + 2]
            if char == "\\" and not raw:
                self.copy(2)
            elif char == "$" and not raw and following == "{":
                self.copy(2)
                self.code(stop_on_brace=True)
            elif char == "$" and not raw and PLAIN_IDENT.match(self.src, self.i + 1):
                self.copy()
                self.word(PLAIN_IDENT)
            else:
                self.copy()


def process(path, mapping, apply):
    src = open(path, encoding="utf-8").read()
    renamer = Renamer(src, mapping)
    renamer.code()
    result = "".join(renamer.out)
    if result != src:
        print("changed" if apply else "would change", path)
        if apply:
            open(path, "w", encoding="utf-8").write(result)
    return renamer.seen


def main():
    args = sys.argv[1:]
    if args[0] == "--idents":
        names = set()
        for path in args[1:]:
            names |= process(path, {}, apply=False)
        for name in sorted(names):
            print(name)
        return
    apply = "--apply" in args
    paths = []
    for arg in args[1:]:
        if arg != "--apply":
            paths.append(arg)
    mapping = load_map(args[0])
    for path in paths:
        process(path, mapping, apply)


main()
