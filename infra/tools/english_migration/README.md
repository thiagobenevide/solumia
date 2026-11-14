# English migration tools

Mechanical, AST-based renames used by the English migration (`docs/GLOSSARIO-INGLES.md`). They only touch what can
be resolved statically; strings (JSON keys, routes, messages) and class fields are never changed. Run from the
repository root (packages under `src/`) with the Python of the venv that runs the tests, then run the tests.

1. `rename_modules.py MAP.json PATHS... [--apply]` — file/package names (`{"pkg.old_module": "new_name"}`), imports
   and names bound by them.
2. `rename_symbols.py _ dictionary.txt [--over=overrides.txt] [--table] [--apply] PATHS...` — module-level
   functions, classes and constants, word by word from the dictionary.
3. `rename_locals.py dictionary.txt [--words] [--apply] PATHS...` — parameters and local variables; parameters
   that are contracts (routes, fixtures, names passed as keyword arguments) are kept. `--words` lists the words
   still missing from the dictionary.
4. `rename_attributes.py dictionary.txt [--over=overrides.txt] [--templates=GLOB,...] [--table] [--apply] PATHS...`
   — methods and instance attributes that are not class fields.

Without `--apply` every tool only reports. `dictionary.txt` is `portuguese english` per line; `overrides.txt` holds
whole names whose word-by-word translation is wrong or reserved.
