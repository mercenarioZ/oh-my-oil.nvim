require("plenary.async").tests.add_to_env()
local TmpDir = require("tests.tmpdir")
local oil = require("oil")
local test_util = require("tests.test_util")
local vcs = require("oil.vcs")

---@param cmd string[]
---@param cwd string
local function sh(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert.equals(0, res.code, table.concat({ vim.inspect(cmd), res.stdout, res.stderr }, "\n"))
end

---git fixture: one modified file, one untracked file, a clean file, and a
---directory whose only change is a modified file inside it
---@param dir string
local function init_git_repo(dir)
  vim.fn.mkdir(dir .. "/sub", "p")
  sh({ "git", "init", "-q" }, dir)
  vim.fn.writefile({ "v1" }, dir .. "/dirty.txt")
  vim.fn.writefile({ "keep" }, dir .. "/keep.txt")
  vim.fn.writefile({ "v1" }, dir .. "/sub/change.txt")
  vim.fn.writefile({ "keep" }, dir .. "/sub/keep.txt")
  sh({ "git", "add", "-A" }, dir)
  sh({
    "git",
    "-c",
    "user.email=oil@test.invalid",
    "-c",
    "user.name=oil tests",
    "commit",
    "-qm",
    "init",
  }, dir)
  vim.fn.writefile({ "v2" }, dir .. "/dirty.txt")
  vim.fn.writefile({ "new" }, dir .. "/untracked.txt")
  vim.fn.writefile({ "v2" }, dir .. "/sub/change.txt")
end

---jj fixture: adds a rename and a directory that stays clean, so a nested write
---can be observed on its own
---@param dir string
---@param colocate boolean
local function init_jj_repo(dir, colocate)
  vim.fn.mkdir(dir .. "/sub", "p")
  vim.fn.mkdir(dir .. "/docs", "p")
  sh({ "jj", "git", "init", colocate and "--colocate" or "--no-colocate" }, dir)
  -- a user config normally provides these; the fixture must not depend on it
  sh({ "jj", "config", "set", "--repo", "user.name", "oil tests" }, dir)
  sh({ "jj", "config", "set", "--repo", "user.email", "oil@test.invalid" }, dir)
  vim.fn.writefile({ "v1" }, dir .. "/dirty.txt")
  vim.fn.writefile({ "old" }, dir .. "/old.txt")
  vim.fn.writefile({ "keep" }, dir .. "/keep.txt")
  vim.fn.writefile({ "v1" }, dir .. "/sub/change.txt")
  vim.fn.writefile({ "keep" }, dir .. "/sub/keep.txt")
  vim.fn.writefile({ "keep" }, dir .. "/docs/keep.md")
  sh({ "jj", "commit", "-m", "init" }, dir)
  vim.fn.writefile({ "v2" }, dir .. "/dirty.txt")
  vim.fn.writefile({ "new" }, dir .. "/added.txt")
  vim.fn.rename(dir .. "/old.txt", dir .. "/renamed.txt")
  vim.fn.writefile({ "v2" }, dir .. "/sub/change.txt")
end

local function it_with_jj(name, fn)
  if vim.fn.executable("jj") == 1 then
    a.it(name, fn)
  else
    a.pending(name .. " (jj is not installed)", function() end)
  end
end

a.describe("vcs column", function()
  local tmpdir
  ---@type integer
  local oil_buf
  ---@type string
  local oil_dir

  a.before_each(function()
    tmpdir = TmpDir.new()
    oil_buf = nil
    oil_dir = nil
  end)

  a.after_each(function()
    vcs.clear()
    if tmpdir then
      tmpdir:dispose()
      tmpdir = nil
    end
    test_util.reset_editor()
  end)

  ---@param opts? oil.SetupVcsOptions
  local function setup(opts)
    oil.setup({
      columns = { "vcs" },
      view_options = { show_hidden = true },
      vcs = opts,
    })
  end

  ---@param dir string
  local function open(dir)
    test_util.actions.open({ dir })
    oil_buf = vim.api.nvim_get_current_buf()
    oil_dir = assert(oil.get_current_dir(oil_buf))
  end

  ---@return table<string, string> listing entry name -> text drawn in the column
  local function codes()
    local out = {}
    for _, line in ipairs(vim.api.nvim_buf_get_lines(oil_buf, 0, -1, true)) do
      local parts = vim.split(line, "%s+", { trimempty = true })
      if #parts >= 2 then
        out[parts[#parts]] = parts[#parts - 1]
      end
    end
    return out
  end

  ---@param want table<string, string> entry name -> expected column text, "-" means clean
  local function expect_column(want)
    local settled = vim.wait(10000, function()
      local got = codes()
      for name, code in pairs(want) do
        if got[name] ~= code then
          return false
        end
      end
      return true
    end, 50)
    local got = codes()
    if not settled then
      local backend = vcs.detect_backend(oil_dir)
      print(table.concat(vim.api.nvim_buf_get_lines(oil_buf, 0, -1, true), "\n"))
      print(vim.inspect({
        got = got,
        want = want,
        status = vcs.get_status(oil_dir),
        backend = backend and backend.name,
      }))
    end
    assert.is_true(settled, "the vcs column never settled")
    for name, code in pairs(want) do
      assert.equals(code, got[name], name)
    end
  end

  ---@param path string
  local function write_file(path)
    vim.cmd("vsplit " .. vim.fn.fnameescape(path))
    vim.cmd("normal! Gox")
    vim.cmd("write")
    vim.cmd("close")
  end

  a.it("shows the status of a git repository", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    setup()
    open(repo)
    expect_column({
      ["dirty.txt"] = "M",
      ["untracked.txt"] = "?",
      ["keep.txt"] = "-",
      ["sub/"] = "M",
    })
  end)

  it_with_jj("shows the status of a jj repository", function()
    local repo = tmpdir.path .. "/jj"
    init_jj_repo(repo, true)
    setup()
    open(repo)
    expect_column({
      ["dirty.txt"] = "M",
      ["added.txt"] = "A",
      ["renamed.txt"] = "R",
      ["keep.txt"] = "-",
      ["sub/"] = "M",
    })
  end)

  it_with_jj("does not leak changes from outside the listed directory", function()
    local repo = tmpdir.path .. "/jj"
    init_jj_repo(repo, true)
    setup()
    open(repo .. "/sub")
    expect_column({ ["change.txt"] = "M", ["keep.txt"] = "-", ["../"] = "-" })
  end)

  it_with_jj("refreshes after a file below the listed directory is written", function()
    local repo = tmpdir.path .. "/jj"
    init_jj_repo(repo, true)
    setup()
    open(repo)
    expect_column({ ["keep.txt"] = "-", ["docs/"] = "-" })

    write_file(repo .. "/keep.txt")
    expect_column({ ["keep.txt"] = "M" })

    -- a write deeper down updates the directory that contains it
    write_file(repo .. "/docs/nested.txt")
    expect_column({ ["docs/"] = "A" })
  end)

  a.it("warns once when the command fails and recovers afterwards", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    setup()
    open(repo)
    expect_column({ ["dirty.txt"] = "M" })

    local notified = {}
    local notify = vim.notify
    local path = vim.env.PATH
    vim.notify = function(msg, ...)
      notified[#notified + 1] = tostring(msg)
      return notify(msg, ...)
    end
    vim.env.PATH = "/nonexistent"
    vcs.load(oil_dir, true)
    vim.wait(2000, function()
      return notified[1] ~= nil
    end, 50)
    -- failing again is not a new failure spell, so it must not warn again
    vcs.load(oil_dir, true)
    vim.env.PATH = path
    vim.notify = notify

    assert.is_truthy(notified[1], "a failing backend must warn")
    assert.is_truthy(notified[1]:match("oil: git failed"), notified[1])
    assert.equals(1, #notified, "the failure should only warn once")
    -- unknown is not the same as clean, but the listing itself must survive
    assert.is_truthy(codes()["dirty.txt"], "the listing broke when the command failed")

    vcs.load(oil_dir, true)
    expect_column({ ["dirty.txt"] = "M", ["untracked.txt"] = "?" })
  end)

  a.it("supports custom symbols and stays parseable", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    setup({ symbols = { M = "\u{271A}" } })
    open(repo)
    expect_column({ ["dirty.txt"] = "\u{271A}", ["untracked.txt"] = "?", ["keep.txt"] = "-" })

    -- oil parses every line of the buffer on write, so the column must round-trip
    local _, errors = require("oil.mutator.parser").parse(oil_buf)
    assert.are.same({}, errors)

    write_file(repo .. "/parsed.txt")
    local refreshed = vim.wait(3000, function()
      return vim.fn.filereadable(repo .. "/parsed.txt") == 1
        and (vcs.get_status(oil_dir) or {})["parsed.txt"] == "?"
    end, 50)
    assert.is_true(refreshed, "the status was not refreshed after a write")
  end)

  a.it("derives highlight colors from the colorscheme", function()
    setup()
    for _, group in ipairs({ "OilVcsModified", "OilVcsAdded", "OilVcsDeleted", "OilVcsUntracked" }) do
      local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
      assert.is_truthy(hl.fg, group .. " has no foreground color")
      assert.is_true(hl.bold, group .. " is not bold")
    end

    vim.cmd.colorscheme("default")
    local after = vim.api.nvim_get_hl(0, { name = "OilVcsModified", link = false })
    assert.is_truthy(after.fg, "colors were lost after a colorscheme switch")
  end)

  a.it("tints filenames when highlight_filename is set", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    setup({ highlight_filename = true })
    open(repo)
    expect_column({ ["dirty.txt"] = "M" })
    local settled = vim.wait(10000, function()
      return vcs.highlight_filename({ name = "dirty.txt" }, false, false, false, oil_buf)
        == "OilVcsModified"
    end, 50)
    assert.is_true(settled, "the filename highlight never settled")
    assert.equals(
      "OilVcsModified",
      vcs.highlight_filename({ name = "dirty.txt" }, false, false, false, oil_buf)
    )
    assert.is_nil(
      vcs.highlight_filename({ name = "keep.txt" }, false, false, false, oil_buf),
      "clean entries keep OilFile/OilDir"
    )
    assert.is_nil(
      vcs.highlight_filename({ name = ".." }, false, false, false, oil_buf),
      "parent entry is never tinted"
    )
  end)

  a.it("lets a user highlight_filename win over the vcs tint", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    oil.setup({
      columns = { "vcs" },
      view_options = {
        show_hidden = true,
        highlight_filename = function()
          return "CustomGroup"
        end,
      },
      vcs = { highlight_filename = true },
    })
    open(repo)
    expect_column({ ["dirty.txt"] = "M" })
    assert.equals("CustomGroup", require("oil.config").view_options.highlight_filename())
    assert.equals(
      "OilVcsModified",
      vcs.highlight_filename({ name = "dirty.txt" }, false, false, false, oil_buf)
    )
  end)

  a.it("does not tint filenames without the vcs column", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    oil.setup({
      columns = { "icon" },
      view_options = { show_hidden = true },
      vcs = { highlight_filename = true },
    })
    open(repo)
    vim.wait(500)
    assert.is_nil(require("oil.config").view_options.highlight_filename)
  end)

  it_with_jj("uses the jj backend in a repository without git", function()
    local repo = tmpdir.path .. "/jj-plain"
    init_jj_repo(repo, false)
    assert.equals(0, vim.fn.isdirectory(repo .. "/.git"), "fixture must not be colocated")
    setup()
    assert.equals("jj", assert(vcs.detect_backend(repo .. "/")).name)
    open(repo)
    expect_column({
      ["dirty.txt"] = "M",
      ["added.txt"] = "A",
      ["renamed.txt"] = "R",
      ["keep.txt"] = "-",
    })
  end)

  it_with_jj("follows the configured backend order", function()
    local repo = tmpdir.path .. "/jj"
    init_jj_repo(repo, true)
    -- a filesystem rename that jj has not snapshotted yet: git reports it as
    -- delete plus untracked, jj would report one rename. No jj command has run
    -- since the rename, so the backend order decides which answer the column shows.
    setup({ backends = { "git", "jj" } })
    assert.equals("git", assert(vcs.detect_backend(repo .. "/")).name)
    open(repo)
    expect_column({ ["renamed.txt"] = "?", ["added.txt"] = "?", ["dirty.txt"] = "M" })
  end)

  it_with_jj("prefers the closest repository", function()
    local repo = tmpdir.path .. "/outer"
    init_jj_repo(repo, true)
    -- a git checkout nested inside the jj repository belongs to git
    local inner = repo .. "/sub/inner"
    init_git_repo(inner)
    setup()
    assert.equals("git", assert(vcs.detect_backend(inner .. "/")).name)
    open(inner)
    expect_column({ ["dirty.txt"] = "M", ["untracked.txt"] = "?", ["keep.txt"] = "-" })
  end)

  a.it("does not fetch anything when the column is not shown", function()
    local repo = tmpdir.path .. "/git"
    init_git_repo(repo)
    oil.setup({ columns = { "icon" }, view_options = { show_hidden = true } })
    test_util.actions.open({ repo })
    local dir = assert(oil.get_current_dir(0))
    vim.wait(500)
    assert.is_nil(vcs.get_status(dir), "the status was fetched without the column")
  end)
end)
