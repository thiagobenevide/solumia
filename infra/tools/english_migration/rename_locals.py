"""locren.py DICT [--apply|--words] [--skip=prefix,...] PATHS... — renames parameters and local variables.

A name is renamed inside one top-level function (and everything nested in it) when the translated name is not
used there. Parameters are renamed only in undecorated, non-test functions and only when the name is never passed
as a keyword argument anywhere in the given files. Class attributes and module-level names are left alone."""
import ast
import builtins
import collections
import keyword
import re
import subprocess
import sys
from pathlib import Path

DICT = sys.argv[1]
APPLY, WORDS_MODE = "--apply" in sys.argv, "--words" in sys.argv
SKIP = tuple(p for a in sys.argv if a.startswith("--skip=") for p in a[7:].split(","))
PATHS = [a for a in sys.argv[2:] if not a.startswith("--")]
WORDS = dict(line.split() for line in Path(DICT).read_text().splitlines() if line.strip())
CONNECT = {"e", "ou", "de", "do", "da", "na", "no", "ao", "so", "por", "com", "sem", "para", "ja", "nao", "sim", "tem"}
TOKEN = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+")
RESERVED = set(dir(builtins)) | set(keyword.kwlist)
ALT = {"list": "items", "all": "everything", "format": "fmt", "filter": "criteria", "map": "mapping",
       "input": "entry", "next": "following", "range": "band", "set": "group", "type": "kind", "id": "ident",
       "open": "opened", "sum": "total", "min": "lowest", "max": "highest", "compile": "compiled",
       "import": "imported", "object": "obj", "hash": "digest", "dir": "folder", "print": "printed",
       "round": "rounded", "slice": "part", "iter": "iterator", "len": "length", "str": "string", "exit": "leave",
       "vars": "variables", "zip": "zipped", "property": "prop", "eval": "evaluated", "exec": "executed",
       "license": "licence", "credits": "credit", "any": "some", "abs": "absolute", "bin": "binary",
       "bytes": "raw_bytes", "dict": "table", "tuple": "pair", "int": "integer", "float": "decimal",
       "bool": "flag", "help": "hint", "repr": "representation", "super": "parent", "pow": "power",
       "not": "negated", "or": "either", "and": "both", "in": "inside", "is": "equals", "for": "towards",
       "with": "along", "from": "origin", "as": "like", "pass": "skip", "class": "klass", "def": "definition",
       "if": "when", "else": "otherwise", "try": "attempt", "while": "during", "yield": "produce",
       "return": "result", "raise": "lift", "global": "overall", "lambda": "fn", "del": "delete",
       "assert": "ensure", "break": "stop", "continue": "proceed", "except": "unless", "finally": "lastly",
       "None": "nothing", "True": "yes", "False": "no", "async": "asynchronous", "await": "wait",
       "nonlocal": "outer", "copyright": "rights", "quit": "leave", "callable": "fn", "divmod": "quotient",
       "sorted": "ordered", "reversed": "backwards", "enumerate": "numbered", "frozenset": "frozen",
       "memoryview": "view", "complex": "compound", "chr": "char", "ord": "ordinal", "oct": "octal",
       "hex": "hexa", "ascii": "plain", "locals": "local_names", "globals": "global_names", "staticmethod": "static",
       "classmethod": "class_method", "isinstance": "instance_of", "issubclass": "subclass_of",
       "getattr": "attribute", "setattr": "assign", "hasattr": "has", "delattr": "drop", "breakpoint": "pause",
       "match": "found", "case": "instance"}


def translate(name):
    if name.startswith("__") or name in ("self", "cls"):
        return name
    tokens = [t for t in TOKEN.findall(name) if not t.isdigit()]
    if len(tokens) == 1 and len(tokens[0]) <= 2:
        return name

    def one(m):
        tok = m.group(0)
        low = tok.lower()
        if low not in WORDS:
            return tok
        if low in CONNECT and (len(tokens) < 2 or tok != low):
            return tok
        new = WORDS[low]
        if tok.isupper() and len(tok) > 1:
            return new.upper()
        if tok[0].isupper():
            return "".join(p.capitalize() for p in new.split("_"))
        return new
    new = TOKEN.sub(one, name)
    core = new.strip("_")
    if core in RESERVED or core in ("match", "case"):
        new = new.replace(core, ALT.get(core, core + "_value"))
    return new


FILES = [Path(f) for f in subprocess.run(["git", "ls-files", *PATHS], capture_output=True, text=True).stdout.split()
         if f.endswith(".py") and "/dados/" not in f]
TREES = {f: ast.parse(f.read_text()) for f in FILES}
KWARGS = set()
for tree in TREES.values():
    for node in ast.walk(tree):
        if isinstance(node, ast.keyword) and node.arg:
            KWARGS.add(node.arg)
FUNCS = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
COMPS = (ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp)
FREE_DECOS = {"staticmethod", "classmethod", "property", "contextmanager", "cache", "lru_cache", "cached_property"}


class Scope:
    def __init__(self, parent, kind, node=None):
        self.parent, self.kind, self.node = parent, kind, node
        self.bind = {}      # name -> "param" | "local" | "import" | "def" | "class-attr"
        self.outer = set()  # global / nonlocal declarations

    def find(self, name):
        scope = self
        skip_class = False
        while scope:
            if name in scope.outer:
                scope = scope.parent
                while scope and name not in scope.bind and scope.parent:
                    scope = scope.parent
                return scope if scope and name in scope.bind else None
            if name in scope.bind and not (skip_class and scope.kind == "class"):
                return scope
            skip_class = True
            scope = scope.parent
        return None


def frozen_params(node, path):
    """True when the parameters of this function are a contract (routes, fixtures, tests)."""
    if isinstance(node, ast.Lambda):
        return False
    if path.name.startswith("test_") or path.name == "conftest.py":
        return True
    for d in node.decorator_list:
        target = d.func if isinstance(d, ast.Call) else d
        name = target.attr if isinstance(target, ast.Attribute) else getattr(target, "id", "")
        if name not in FREE_DECOS:
            return True
    return False


def build(node, scope, uses, path, top):
    if isinstance(node, (ast.Global, ast.Nonlocal)):
        scope.outer.update(node.names)
        if isinstance(node, ast.Nonlocal):
            uses.append((node, scope, top, "nonlocal"))
        return
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        for a in node.names:
            scope.bind[(a.asname or a.name).split(".")[0]] = "import"
        return
    if isinstance(node, ast.Name):
        uses.append((node, scope, top, "name"))
        if not isinstance(node.ctx, ast.Load) and node.id not in scope.outer:
            scope.bind.setdefault(node.id, "class-attr" if scope.kind == "class" else "local")
        return
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        scope.bind.setdefault(node.name, "def")
    if isinstance(node, ast.ExceptHandler) and node.name:
        scope.bind.setdefault(node.name, "local")
        uses.append((node, scope, top, "except"))
    if isinstance(node, (ast.MatchAs, ast.MatchStar)) and node.name:
        scope.bind.setdefault(node.name, "frozen")
    inner = scope
    if isinstance(node, FUNCS + COMPS + (ast.ClassDef,)):
        kind = "class" if isinstance(node, ast.ClassDef) else "func" if isinstance(node, FUNCS) else "comp"
        inner = Scope(scope, kind, node)
        if top is None and kind == "func":
            top = node
        if kind == "func":
            frozen = frozen_params(node, path)
            args = node.args
            for a in args.posonlyargs + args.args + args.kwonlyargs + [x for x in (args.vararg, args.kwarg) if x]:
                inner.bind[a.arg] = "frozen" if frozen or a.arg in KWARGS else "param"
                uses.append((a, inner, top, "arg"))
    for child in ast.iter_child_nodes(node):
        build(child, inner, uses, path, top)


unknown = collections.Counter()
total = skipped = 0
for path, tree in TREES.items():
    if str(path).startswith(SKIP):
        continue
    root = Scope(None, "module")
    uses = []
    build(tree, root, uses, path, None)
    lines = path.read_text().split("\n")
    groups = {}     # (id(top), old) -> [(line, col)]
    blocked = set()
    taken = collections.defaultdict(set)
    for node, scope, top, kind in uses:
        if top is None:
            continue
        if kind == "name":
            taken[id(top)].add(node.id)
            owner = scope.find(node.id)
            if owner is None or owner.kind in ("module", "class"):
                continue
            state = owner.bind[node.id]
            key = (id(top), node.id)
            if state in ("import", "def", "frozen", "class-attr"):
                blocked.add(key)
                continue
            groups.setdefault(key, []).append((node.lineno, node.col_offset))
        elif kind == "arg":
            taken[id(top)].add(node.arg)
            key = (id(top), node.arg)
            if scope.bind[node.arg] == "frozen":
                blocked.add(key)
            else:
                groups.setdefault(key, []).append((node.lineno, node.col_offset))
        elif kind == "except":
            key = (id(top), node.name)
            raw = lines[node.lineno - 1].encode()
            m = re.compile(rb"\bas\s+(" + node.name.encode() + rb")\b").search(raw, node.col_offset)
            if m:
                groups.setdefault(key, []).append((node.lineno, m.start(1)))
            else:
                blocked.add(key)
        elif kind == "nonlocal":
            raw = lines[node.lineno - 1].encode()
            for n in node.names:
                m = re.compile(rb"\b" + n.encode() + rb"\b").search(raw, node.col_offset + 8)
                groups.setdefault((id(top), n), []).append((node.lineno, m.start()))
    edits = []
    planned = collections.defaultdict(set)
    for (top_id, old), sites in sorted(groups.items(), key=lambda kv: kv[1][0]):
        new = translate(old)
        if new == old:
            for t in TOKEN.findall(old):
                if len(t) > 2 and t.lower() not in WORDS:
                    unknown[t.lower()] += 1
            continue
        if (top_id, old) in blocked or new in taken[top_id] or new in planned[top_id] or not new.isidentifier():
            skipped += 1
            continue
        planned[top_id].add(new)
        total += 1
        for line, col in sites:
            edits.append((line, col, old, new))
    if APPLY and edits:
        ok = True
        for line, col, old, new in sorted(set(edits), reverse=True):
            raw = lines[line - 1].encode()
            if raw[col:col + len(old.encode())] != old.encode():
                print(f"WARNING {path}:{line} position mismatch for {old}; file left untouched")
                ok = False
                break
            lines[line - 1] = (raw[:col] + new.encode() + raw[col + len(old.encode()):]).decode()
        if ok:
            path.write_text("\n".join(lines))
print(f"{total} renames, {skipped} kept (collision or contract)")
if WORDS_MODE:
    print(" ".join(f"{w}:{n}" for w, n in unknown.most_common(450)))
