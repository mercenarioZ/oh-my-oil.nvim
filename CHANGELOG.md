# Changelog

All notable changes to oh-my-oil are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version line starts here: 0.1.0 is the fork's first release and does not
continue oil.nvim's version numbers. The history of everything this fork
inherits from oil.nvim up to v2.16.0 lives in the
[upstream changelog](https://github.com/stevearc/oil.nvim/blob/master/CHANGELOG.md).

## 1.0.0 (2026-10-04)


### Features

* **vcs:** tint filename with status highlight ([6a5e4ec](https://github.com/mercenarioZ/oh-my-oil.nvim/commit/6a5e4ec57fed12a4054d07c3303727bf21b1d45d))


### Bug Fixes

* keep minor bumps before 1.0 ([87ad2c8](https://github.com/mercenarioZ/oh-my-oil.nvim/commit/87ad2c857ed98f82377ee58a4eb2cf46822187e8))

## [0.1.0] - 2026-10-01

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
