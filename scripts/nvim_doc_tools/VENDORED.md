# nvim_doc_tools (vendored)

This directory is a copy of
[stevearc/nvim_doc_tools](https://github.com/stevearc/nvim_doc_tools), the
library that renders `doc/oil.txt`, `doc/api.md` and the table of contents in
`README.md`.

- Upstream: <https://github.com/stevearc/nvim_doc_tools>
- Commit: `d0734723f3e29505c0e830ac986746f10d2f431c` (2025-10-20, "feat:
  functions for rendering classes")
- License: MIT, see `LICENSE` (copyright Steven Arcangeli)
- Vendored on: 2026-10-01

Kept from upstream, unmodified: `__init__.py`, `apidoc.py`, `lint_md_links.py`,
`markdown.py`, `parser.py`, `util.py`, `vimdoc.py`.

Dropped, because the generator does not use them: the upstream tests and
packaging files (`.github/`, `test/`, `tox.ini`, `pyproject.toml`,
`.pylintrc`, `.envrc`).

`scripts/generate.py` imports this package through `sys.path` (see
`scripts/main.py`), so nothing has to be installed. `make doc` only builds the
virtualenv from `scripts/requirements.txt` and then runs the generator.

To update: copy the newer files over this directory, keep `LICENSE` and this
note, then run `make doc` and check the diff in `doc/` and `README.md` against
what you expected.
