# Changelog

All notable changes to oh-my-oil are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version line starts here: 0.1.0 is the fork's first release and does not
continue oil.nvim's version numbers. The history of everything this fork
inherits from oil.nvim up to v2.16.0 lives in the
[upstream changelog](https://github.com/stevearc/oil.nvim/blob/master/CHANGELOG.md).

## [0.2.1](https://github.com/mercenarioZ/oh-my-oil.nvim/compare/v0.2.0...v0.2.1) (2026-10-04)


### Bug Fixes

* redraw after directory navigation ([230559d](https://github.com/mercenarioZ/oh-my-oil.nvim/commit/230559d8e3cf935d4528f4d50af8f0ae2fd0a893))

## [Unreleased]

### Fixed

- Schedule navigation preview updates after cursor restoration and explicitly
  redraw when navigation and preview opening complete.

## [0.2.0] - 2026-10-04

### Added

- `vcs.highlight_filename`: tint the filename itself with the same group as
  the version control column. Clean entries keep `OilFile`/`OilDir`. Needs the
  `vcs` column; a user `view_options.highlight_filename` wins
  (`:help oil-vcs-highlights`)

### Fixed

- keep minor bumps before 1.0: `bump-minor-pre-major` belongs in
  `packages["."]`, not at the config root


### Added

- oh-my-oil, a fork of [oil.nvim](https://github.com/stevearc/oil.nvim) v2.16.0
  maintained by [mercenarioZ](https://github.com/mercenarioZ)
- the `vcs` column, merged from
  [voil.nvim](https://github.com/mercenarioZ/voil.nvim): one character per entry
  with its version control status, from `jj` or `git`, with per-directory
  caching, a warning and a backoff when the command fails, and highlights
  derived from the colorscheme (`:help oil-vcs`)
- tests for the column in `tests/vcs_spec.lua`

### Changed

- the user command is `:OhMyOil`, with `:OMO` as a short alias; `:Oil` is gone
  (`:help oil-commands`)
