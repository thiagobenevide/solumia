"""attrren.py DICT [--apply] [--over=FILE] [--templates=GLOB,...] PATHS... — renames methods and instance attributes.

An attribute name is renamed everywhere (`def` inside classes, every `.name`, constant names in getattr/setattr)
when it is a method or a `self.name = ...` attribute of some class in PATHS and is not: a class-level field
(Pydantic/dataclass fields are JSON contracts), a module-level name, a name used in the templates, a member of a
class that dispatches with a computed getattr, or a name whose translation is already an attribute somewhere."""
import ast
import builtins
import keyword
import re
import subprocess
import sys
from pathlib import Path

DICT = sys.argv[1]
APPLY = "--apply" in sys.argv
OVER = {}
TEMPLATES = []
for a in sys.argv:
    if a.startswith("--over="):
        for line in Path(a[7:]).read_text().split("\n"):
            if line.strip():
                key, value = line.split()
                OVER[key] = value
    if a.startswith("--templates="):
        TEMPLATES = a[12:].split(",")
PATHS = [a for a in sys.argv[2:] if not a.startswith("--")]
WORDS = dict(line.split() for line in Path(DICT).read_text().splitlines() if line.strip())
CONNECT = {"e", "ou", "de", "do", "da", "na", "no", "ao", "so", "por", "com", "sem", "para", "ja", "nao", "sim", "tem"}
TOKEN = re.compile(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+")
RESERVED = set(dir(builtins)) | set(keyword.kwlist)


def translate(name):
    if name in OVER:
        return OVER[name]
    if name.startswith("__"):
        return name
    tokens = [t for t in TOKEN.findall(name) if not t.isdigit()]
    if len(tokens) == 1 and len(tokens[0]) <= 2:
        return name

    def one(m):
        tok = m.group(0)
        low = tok.lower()
        if low not in WORDS or (low in CONNECT and (len(tokens) < 2 or tok != low)):
            return tok
        new = WORDS[low]
        if tok.isupper() and len(tok) > 1:
            return new.upper()
        if tok[0].isupper():
            return "".join(p.capitalize() for p in new.split("_"))
        return new
    return TOKEN.sub(one, name)


FILES = [Path(f) for f in subprocess.run(["git", "ls-files", *PATHS], capture_output=True, text=True).stdout.split()
         if f.endswith(".py") and "/dados/" not in f]
TREES = {f: ast.parse(f.read_text()) for f in FILES}
members, fields, toplevel, used, dynamic = set(), set(), set(), set(), set()
for f, tree in TREES.items():
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            toplevel.add(node.name)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            for t in (node.targets if isinstance(node, ast.Assign) else [node.target]):
                for n in ast.walk(t):
                    if isinstance(n, ast.Name):
                        toplevel.add(n.id)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for a in node.names:
                toplevel.add((a.asname or a.name).split(".")[0])
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            used.add(node.attr)
            if isinstance(node.ctx, ast.Store) and isinstance(node.value, ast.Name) and node.value.id == "self":
                members.add(node.attr)
        elif isinstance(node, ast.ClassDef):
            names = set()
            computed = False
            for item in node.body:
                if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    names.add(item.name)
                elif isinstance(item, (ast.Assign, ast.AnnAssign)):
                    for t in (item.targets if isinstance(item, ast.Assign) else [item.target]):
                        for n in ast.walk(t):
                            if isinstance(n, ast.Name):
                                fields.add(n.id)
            for sub in ast.walk(node):
                if isinstance(sub, ast.Call) and getattr(sub.func, "id", "") == "getattr" and len(sub.args) > 1 \
                        and not isinstance(sub.args[1], ast.Constant):
                    computed = True
            if computed:
                dynamic.update(names)
            members.update(names)
template_text = ""
for pattern in TEMPLATES:
    for f in subprocess.run(["git", "ls-files", pattern], capture_output=True, text=True).stdout.split():
        template_text += Path(f).read_text(errors="ignore")
in_templates = set(re.findall(r"\.([A-Za-z_]\w*)", template_text))
RENAME, skipped = {}, []
taken = set(used) | fields | members
for name in sorted(members):
    new = translate(name)
    if new == name:
        continue
    reason = None
    if name in fields:
        reason = "field"
    elif name in toplevel:
        reason = "module-level name"
    elif name in dynamic:
        reason = "computed getattr"
    elif name in in_templates:
        reason = "template"
    elif not new.isidentifier() or new.strip("_") in RESERVED:
        reason = f"'{new}' reserved"
    elif new in taken or new in RENAME.values():
        reason = f"'{new}' exists"
    if reason:
        skipped.append(f"{name} ({reason})")
        continue
    RENAME[name] = new
print(f"{len(RENAME)} attributes renamed, {len(skipped)} kept")
if "--table" in sys.argv:
    print(" ".join(f"{k}→{v}" for k, v in sorted(RENAME.items())))
    print("KEPT:", "; ".join(skipped))
if APPLY:
    for f, tree in TREES.items():
        lines = f.read_text().split("\n")
        edits = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and node.attr in RENAME:
                edits.append((node.end_lineno, node.end_col_offset - len(node.attr.encode()), node.attr))
            elif isinstance(node, ast.ClassDef):
                for item in node.body:
                    if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name in RENAME:
                        raw = lines[item.lineno - 1].encode()
                        m = re.compile(rb"def\s+(" + item.name.encode() + rb")\b").search(raw, item.col_offset)
                        edits.append((item.lineno, m.start(1), item.name))
            elif isinstance(node, ast.Call):
                fn = node.func
                name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", "")
                if name in ("getattr", "setattr", "hasattr", "delattr", "object") and len(node.args) > 1:
                    const = node.args[1]
                    if isinstance(const, ast.Constant) and const.value in RENAME:
                        edits.append((const.lineno, const.col_offset + 1, const.value))
        for line, col, old in sorted(set(edits), reverse=True):
            raw = lines[line - 1].encode()
            assert raw[col:col + len(old.encode())] == old.encode(), (f, line, col, old)
            lines[line - 1] = (raw[:col] + RENAME[old].encode() + raw[col + len(old.encode()):]).decode()
        if edits:
            f.write_text("\n".join(lines))
