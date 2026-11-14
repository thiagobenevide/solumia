"""modmove.py PKG MAP.json [--apply] — renames modules of package PKG (run at the folder that holds PKG).

MAP.json: {"top": {old: new}, "sub": {old_pkg: {old: new}}}. Moves files with git mv, rewrites import statements,
names bound by those imports (scope-aware) and attribute chains that walk into renamed submodules.
"""
import ast
import json
import re
import subprocess
import sys
from pathlib import Path

MAP = json.loads(Path(sys.argv[1]).read_text())   # {old dotted module: new basename}
APPLY = "--apply" in sys.argv
HEAD = "--head" in sys.argv
EXTRA = [a for a in sys.argv[2:] if not a.startswith("--")]
def new_dotted(dotted):
    parts = dotted.split(".")
    out = []
    for i, part in enumerate(parts):
        out.append(MAP.get(".".join(parts[:i + 1]), part))
    return ".".join(out)


MODULES = set()
LIST = ["git", "ls-files"]
SRC = {}
for f in subprocess.run([*LIST, *EXTRA], capture_output=True, text=True).stdout.split():
    if f.endswith(".py") and "/src/" in f:
        parts = f[:-3].split("/")
        parts = parts[len(parts) - parts[::-1].index("src"):]
        if parts[-1] == "__init__":
            parts = parts[:-1]
        SRC[".".join(parts)] = f
        for i in range(1, len(parts) + 1):
            MODULES.add(".".join(parts[:i]))
ROOTS = {x.split(".")[0] for x in MODULES}

SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ListComp, ast.SetComp, ast.DictComp,
          ast.GeneratorExp, ast.ClassDef)


class Scope:
    def __init__(self, parent):
        self.parent = parent
        self.bind = {}

    def bound(self, name):
        scope = self
        while scope:
            if name in scope.bind:
                return True
            scope = scope.parent
        return False

    def resolve(self, name):
        scope = self
        while scope:
            if name in scope.bind:
                return scope.bind[name]
            scope = scope.parent
        return None


def build(node, scope, loads, edits, lines, path):
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        imports(node, scope, edits, lines, path)
        return
    if isinstance(node, ast.Name):
        if isinstance(node.ctx, ast.Load):
            loads[id(node)] = scope
        else:
            if isinstance(scope.bind.get(node.id), str):
                print(f"WARNING {path}:{node.lineno} '{node.id}' is both a module and a variable")
            scope.bind[node.id] = None
        return
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        scope.bind[node.name] = None
    if isinstance(node, ast.ExceptHandler) and node.name:
        scope.bind[node.name] = None
    inner = scope
    if isinstance(node, SCOPES):
        inner = Scope(scope)
        if hasattr(node, "args") and isinstance(node.args, ast.arguments):
            for a in node.args.posonlyargs + node.args.args + node.args.kwonlyargs:
                inner.bind[a.arg] = None
            for a in (node.args.vararg, node.args.kwarg):
                if a:
                    inner.bind[a.arg] = None
    for child in ast.iter_child_nodes(node):
        build(child, inner, loads, edits, lines, path)


def imports(node, scope, edits, lines, path):
    if isinstance(node, ast.ImportFrom):
        if node.level:
            print(f"WARNING {path}:{node.lineno} relative import")
            return
        base = node.module or ""
        if base.split(".")[0] not in ROOTS:
            for a in node.names:
                scope.bind[a.asname or a.name] = None
            return
        if new_dotted(base) != base:
            col = lines[node.lineno - 1].index(base, node.col_offset)
            edits.append((node.lineno, col, base, new_dotted(base)))
        for a in node.names:
            full = f"{base}.{a.name}"
            if full in MODULES:
                new = new_dotted(full).split(".")[-1]
                if new != a.name:
                    edits.append((a.lineno, a.col_offset, a.name, new))
                scope.bind[a.asname or a.name] = None if a.asname else full
            else:
                scope.bind[a.asname or a.name] = None
    else:
        for a in node.names:
            if a.name.split(".")[0] in ROOTS:
                if new_dotted(a.name) != a.name:
                    edits.append((a.lineno, a.col_offset, a.name, new_dotted(a.name)))
                if not a.asname:
                    scope.bind[a.name.split(".")[0]] = a.name.split(".")[0]
                    continue
            scope.bind[a.asname or a.name.split(".")[0]] = None


def chain(node):
    attrs = []
    while isinstance(node, ast.Attribute):
        attrs.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        return node, attrs[::-1]
    return None, None


def process(path):
    src = path.read_text() if not HEAD else subprocess.run(["git", "show", f"HEAD:./{path}"], capture_output=True, text=True).stdout
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        print(f"WARNING {path}: {e}")
        return
    lines = src.split("\n")
    loads, edits = {}, []
    root = Scope(None)
    build(tree, root, loads, edits, lines, path)
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and id(node) in loads:
            full = loads[id(node)].resolve(node.id)
            if isinstance(full, str) and full not in ROOTS:
                new = new_dotted(full).split(".")[-1]
                if new != node.id:
                    if loads[id(node)].bound(new):
                        print(f"COLLISION {path}:{node.lineno} '{node.id}' -> '{new}' is already a name here")
                    edits.append((node.lineno, node.col_offset, node.id, new))
        elif isinstance(node, ast.Attribute):
            base, attrs = chain(node)
            if base is None or id(base) not in loads:
                continue
            full = loads[id(base)].resolve(base.id)
            if not isinstance(full, str):
                continue
            dotted = full + "." + ".".join(attrs)
            if dotted in MODULES:
                new = new_dotted(dotted).split(".")[-1]
                if new != node.attr:
                    edits.append((node.end_lineno, node.end_col_offset - len(node.attr), node.attr, new))
    out = src
    if edits:
        for line, col, old, new in sorted(set(edits), reverse=True):
            text = lines[line - 1]
            # ast columns are UTF-8 byte offsets
            raw = text.encode()
            assert raw[col:col + len(old.encode())] == old.encode(), (path, line, col, old, text)
            lines[line - 1] = (raw[:col] + new.encode() + raw[col + len(old.encode()):]).decode()
        out = "\n".join(lines)
    # dotted names inside strings and comments (monkeypatch targets, `python -m`)
    def dotted_sub(m):
        return new_dotted(m.group(0))
    out2 = re.sub(r"(?<![\w.])" + "(?:" + "|".join(sorted(ROOTS)) + ")" + r"(?:\.[A-Za-z_]\w*)+", dotted_sub, out)
    if out2 != src:
        print(f"edit {path} ({len(set(edits))})")
        if APPLY:
            path.write_text(out2)


files = [Path(f) for f in subprocess.run([*LIST, *EXTRA], capture_output=True, text=True).stdout.split()
         if f.endswith(".py")]
for f in files:
    process(f)
if APPLY:
    # deepest first, so that a package rename does not invalidate the paths of its modules
    for old in sorted(MAP, key=lambda k: -k.count(".")):
        if old not in SRC:
            print("WARNING unknown module", old)
            continue
        src = Path(SRC[old])
        if src.name == "__init__.py":
            subprocess.run(["git", "mv", str(src.parent), str(src.parent.with_name(MAP[old]))], check=True)
        else:
            subprocess.run(["git", "mv", str(src), str(src.with_name(MAP[old] + ".py"))], check=True)
