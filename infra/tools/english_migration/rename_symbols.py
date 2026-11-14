"""symren.py PKG DICT [--apply] [--skip=prefix,prefix] [--over=FILE] EXTRA... — renames module-level names
(functions, classes, constants) of the modules of PKG using a word dictionary; updates every reference that can
be resolved statically (same module, `from m import x`, `m.x`, setattr/getattr strings, dotted strings)."""
import ast
import builtins
import keyword
import re
import subprocess
import sys
from pathlib import Path

DICT = sys.argv[2]
PKG = None
APPLY = "--apply" in sys.argv
SKIP = tuple(p for a in sys.argv if a.startswith("--skip=") for p in a[7:].split(","))
OVER = {}
for a in sys.argv:
    if a.startswith("--over="):
        for line in Path(a[7:]).read_text().split("\n"):
            if line.strip():
                key, value = line.split()
                OVER[key] = value
EXTRA = [a for a in sys.argv[3:] if not a.startswith("--")]
WORDS = dict(line.split() for line in Path(DICT).read_text().splitlines() if line.strip())
CONNECT = {"e", "ou", "de", "do", "da", "na", "no", "ao", "so", "por", "com", "sem", "para", "ja", "nao", "sim", "tem"}
TOKEN = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+")


def translate(name):
    if name in OVER:
        return OVER[name]
    if name.startswith("__"):
        return name
    tokens = [t for t in TOKEN.findall(name) if not t.isdigit()]
    if len(tokens) == 1 and len(tokens[0]) <= 2:
        return name
    upper = name.upper() == name and any(c.isalpha() for c in name)

    def one(m):
        tok = m.group(0)
        low = tok.lower()
        if low not in WORDS or (low in CONNECT and (len(tokens) < 2 or tok != low)):
            if not (low == "no" and len(tokens) >= 2 and low in WORDS):
                return tok
        new = WORDS[low]
        if upper:
            return new.upper()
        if tok[0].isupper():
            return "".join(p.capitalize() for p in new.split("_"))
        return new
    return TOKEN.sub(one, name)


def git_files(*paths):
    out = subprocess.run(["git", "ls-files", *paths], capture_output=True, text=True).stdout.split()
    return [Path(f) for f in out if f.endswith(".py")]


FILES = {}
for f in git_files(*EXTRA):
    parts = list(f.with_suffix("").parts)
    if "src" not in parts:
        FILES[f] = None
        continue
    parts = parts[len(parts) - parts[::-1].index("src"):]
    if parts[-1] == "__init__":
        parts = parts[:-1]
    FILES[f] = ".".join(parts)
MODULES = set()
for m in FILES.values():
    if m:
        bits = m.split(".")
        for i in range(1, len(bits) + 1):
            MODULES.add(".".join(bits[:i]))
ROOTS = {m.split(".")[0] for m in MODULES}
TREES, LINES = {}, {}
for f in FILES:
    src = f.read_text()
    TREES[f] = ast.parse(src)
    LINES[f] = src.split("\n")


def top_names(tree):
    """Module-level names: {name: [nodes]} (defs, classes, assignment targets), plus module-level from-imports."""
    names, imported = {}, {}
    stack = list(tree.body)
    while stack:
        node = stack.pop()
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.setdefault(node.name, [])
        elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for t in targets:
                for n in ast.walk(t):
                    if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                        names.setdefault(n.id, [])
        elif isinstance(node, (ast.If, ast.Try, ast.With, ast.For)):
            for field in ("body", "orelse", "finalbody", "handlers"):
                for child in getattr(node, field, []):
                    stack.extend(child.body if isinstance(child, ast.ExceptHandler) else [child])
        elif isinstance(node, ast.ImportFrom) and not node.level and node.module in MODULES:
            for a in node.names:
                if not a.asname:
                    imported[a.name] = node.module
    return names, imported


OWNER = {}   # (module, name) -> (origin module, name)
IMPORTED = {}
for f, mod in FILES.items():
    if not mod:
        continue
    names, imported = top_names(TREES[f])
    for n in names:
        OWNER[(mod, n)] = (mod, n)
    IMPORTED[mod] = imported
for _ in range(3):
    for mod, imported in IMPORTED.items():
        for n, src in imported.items():
            if (src, n) in OWNER and (mod, n) not in OWNER:
                OWNER[(mod, n)] = OWNER[(src, n)]

NEW, DROP = {}, {}
BUILTINS = set(dir(builtins)) | set(keyword.kwlist)
for (mod, n), origin in OWNER.items():
    if origin != (mod, n) or mod.startswith(SKIP):
        continue
    new = translate(n)
    if new == n:
        continue
    if not new.isidentifier() or new in BUILTINS:
        DROP[(mod, n)] = f"'{new}' is reserved"
        continue
    NEW[(mod, n)] = new
by_new = {}
for (mod, n), new in NEW.items():
    by_new.setdefault((mod, new), []).append(n)
for (mod, new), olds in by_new.items():
    if len(olds) > 1 or ((mod, new) in OWNER and (mod, new) not in NEW):
        for n in olds:
            DROP[(mod, n)] = f"'{new}' already exists in the module"
SCOPES = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ListComp, ast.SetComp, ast.DictComp,
          ast.GeneratorExp, ast.ClassDef)


class Scope:
    def __init__(self, parent):
        self.parent = parent
        self.bind = {}
        self.globals = set()

    def find(self, name):
        scope = self
        while scope:
            if name in scope.globals:
                while scope.parent:
                    scope = scope.parent
            if name in scope.bind:
                return scope, scope.bind[name]
            scope = scope.parent
        return None, None


def build(node, scope, refs, mod, own):
    if isinstance(node, ast.Global):
        scope.globals.update(node.names)
        refs.append(("global", node, scope))
        return
    if isinstance(node, ast.ImportFrom):
        base = node.module or ""
        for a in node.names:
            full = f"{base}.{a.name}"
            if node.level:
                value = None
            elif full in MODULES:
                value = ("mod", full)
            elif (base, a.name) in OWNER:
                value = ("obj",) + OWNER[(base, a.name)] + (a.asname is None,)
                refs.append(("import", a, scope, OWNER[(base, a.name)]))
            else:
                value = None
            scope.bind[a.asname or a.name] = value
        return
    if isinstance(node, ast.Import):
        for a in node.names:
            if a.asname:
                scope.bind[a.asname] = ("mod", a.name) if a.name in MODULES else None
            else:
                root = a.name.split(".")[0]
                scope.bind[root] = ("mod", root) if root in ROOTS else None
        return
    if isinstance(node, ast.Name):
        refs.append(("name", node, scope))
        if not isinstance(node.ctx, ast.Load) and node.id not in scope.globals:
            if not (scope.parent is None and node.id in own):
                scope.bind.setdefault(node.id, None)
        return
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        if scope.parent is None and node.name in own:
            refs.append(("def", node, scope))
        else:
            scope.bind[node.name] = None
    if isinstance(node, ast.ExceptHandler) and node.name:
        scope.bind[node.name] = None
    if isinstance(node, ast.Attribute):
        refs.append(("attr", node, scope))
    if isinstance(node, ast.Call):
        refs.append(("call", node, scope))
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
        build(child, inner, refs, mod, own)


def module_of(expr, scope):
    """Dotted module an expression evaluates to (Name or attribute chain through modules), or None."""
    attrs = []
    while isinstance(expr, ast.Attribute):
        attrs.append(expr.attr)
        expr = expr.value
    if not isinstance(expr, ast.Name):
        return None
    _, value = scope.find(expr.id)
    if not value or value[0] != "mod":
        return None
    cur = value[1]
    for a in reversed(attrs):
        if f"{cur}.{a}" in MODULES:
            cur = f"{cur}.{a}"
        elif (cur, a) in OWNER and OWNER[(cur, a)][0] != cur and False:
            return None
        else:
            return None
    return cur


EDITS = {f: [] for f in FILES}
SITES = []   # (origin, file, line, col, old, scope or None)


def collect(f, mod):
    own = {n for (m, n) in OWNER if m == mod and OWNER[(m, n)] == (m, n)} if mod else set()
    root = Scope(None)
    for n in own:
        root.bind[n] = ("obj", mod, n, True)
    refs = []
    build(TREES[f], root, refs, mod, own)
    for n in own:
        new = NEW.get((mod, n))
        if new and new in root.bind and new not in own:
            DROP[(mod, n)] = f"'{new}' is imported in the module"
    lines = LINES[f]
    for kind, node, scope, *rest in refs:
        if kind == "name":
            _, value = scope.find(node.id)
            if value and value[0] == "obj" and value[3]:
                SITES.append(((value[1], value[2]), f, node.lineno, node.col_offset, node.id, scope))
        elif kind == "def":
            raw = lines[node.lineno - 1].encode()
            m = re.compile(rb"(def|class)\s+" + node.name.encode() + rb"\b").search(raw, node.col_offset)
            SITES.append(((mod, node.name), f, node.lineno, m.end() - len(node.name.encode()), node.name, None))
        elif kind == "import":
            a = node
            SITES.append((rest[0], f, a.lineno, a.col_offset, a.name, scope if not a.asname else None))
        elif kind == "global":
            raw = lines[node.lineno - 1].encode()
            for n in node.names:
                _, value = scope.find(n)
                if value and value[0] == "obj":
                    m = re.compile(rb"\b" + n.encode() + rb"\b").search(raw, node.col_offset)
                    SITES.append(((value[1], value[2]), f, node.lineno, m.start(), n, None))
        elif kind == "attr":
            base = module_of(node.value, scope)
            if base and (base, node.attr) in OWNER:
                SITES.append((OWNER[(base, node.attr)], f, node.end_lineno, node.end_col_offset - len(node.attr),
                              node.attr, None))
        elif kind == "call":
            fn = node.func
            name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", "")
            if name in ("setattr", "getattr", "hasattr", "delattr", "delitem") and len(node.args) >= 2:
                target, const = node.args[0], node.args[1]
                if isinstance(const, ast.Constant) and isinstance(const.value, str):
                    base = module_of(target, scope)
                    if base and (base, const.value) in OWNER:
                        SITES.append((OWNER[(base, const.value)], f, const.lineno, const.col_offset + 1,
                                      const.value, None))


for f, mod in FILES.items():
    collect(f, mod)
for origin, f, line, col, old, scope in SITES:
    if origin not in NEW or origin in DROP:
        continue
    new = NEW[origin]
    if scope is not None:
        where, value = scope.find(new)
        if where is not None and not (value and value[0] == "obj" and (value[1], value[2]) == origin):
            DROP[origin] = f"'{new}' is already a name at {f}:{line}"
for origin, reason in sorted(DROP.items()):
    print(f"SKIP {origin[0]}.{origin[1]}: {reason}")
count = 0
for origin, f, line, col, old, scope in SITES:
    if origin in NEW and origin not in DROP:
        EDITS[f].append((line, col, old, NEW[origin]))
print(f"{sum(1 for o in NEW if o not in DROP)} names renamed, {len(DROP)} skipped")
if "--table" in sys.argv:
    for (mod, n), new in sorted(NEW.items()):
        if (mod, n) not in DROP:
            print(f"{mod}.{n} {new}")
DOTTED = []
for (mod, n), new in NEW.items():
    if (mod, n) not in DROP:
        DOTTED.append((re.compile(r"(?<![\w.])" + re.escape(f"{mod}.{n}") + r"(?!\w)"), f"{mod}.{new}"))
        base = mod.split(".")[-1]
        DOTTED.append((re.compile(r"(`[^`\n]*?(?<![\w.]))" + re.escape(f"{base}.{n}") + r"(?!\w)"), r"\1" + f"{base}.{new}"))
if APPLY:
    targets = dict.fromkeys(list(FILES) + [Path(p) for p in subprocess.run(
        ["git", "ls-files", "*.md"], capture_output=True, text=True).stdout.split()])
    for f in targets:
        lines = LINES.get(f) or f.read_text().split("\n")
        for line, col, old, new in sorted(set(EDITS.get(f, [])), reverse=True):
            raw = lines[line - 1].encode()
            assert raw[col:col + len(old.encode())] == old.encode(), (f, line, col, old)
            lines[line - 1] = (raw[:col] + new.encode() + raw[col + len(old.encode()):]).decode()
        text = "\n".join(lines)
        for rx, new in DOTTED:
            if rx.pattern.split("\\.")[-1].split("(")[0] in text or True:
                text = rx.sub(new, text)
        if text != f.read_text():
            f.write_text(text)
