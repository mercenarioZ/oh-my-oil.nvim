local aggregate = require("oil.vcs.aggregate")
local constants = require("oil.constants")
local highlight = require("oil.vcs.highlight")
local log = require("oil.log")

local FIELD_NAME = constants.FIELD_NAME

local M = {}

---@class oil.VcsHighlight
---@field group string Highlight group to define
---@field base string Highlight group to copy the foreground from
---@field plain nil|boolean Skip the bold attribute

---@class oil.VcsChange
---@field path string Path relative to the directory being listed
---@field code string One character status code

---@class oil.VcsBackend
---@field name string
---@field cmd string[] Command that runs with the listed directory as cwd
---@field detect fun(dir: string): boolean True when the given directory itself holds the repository marker
---@field parse fun(stdout: string): oil.VcsChange[]

---@type nil|oil.VcsOptions Set by config.setup
M.config = nil

local backends = {}
---@type oil.VcsBackend[]
local enabled = {}

-- dir -> { [entry name] = code }; a missing key means "not fetched yet"
local cache = {}
local inflight = {}
-- every dir the column has asked for, including the ones whose fetch failed
local tracked = {}
-- dir -> time before which a failed fetch is not retried
local retry_at = {}

---Register a backend so that it can be named in the `vcs.backends` option.
---@param backend oil.VcsBackend
M.register_backend = function(backend)
  backends[backend.name] = backend
end

M.register_backend(require("oil.vcs.backends.git"))
M.register_backend(require("oil.vcs.backends.jj"))

---@param dir string
---@return nil|oil.VcsBackend
M.detect_backend = function(dir)
  -- The closest repository wins: a checkout that is nested inside another one
  -- belongs to the inner one. Within one directory the configured order decides.
  local candidate = dir
  while #enabled > 0 do
    for _, backend in ipairs(enabled) do
      if backend.detect(candidate) then
        return backend
      end
    end
    local parent = vim.fs.dirname(candidate)
    if parent == candidate or parent == "" then
      return nil
    end
    candidate = parent
  end
end

---@param dir string
---@return nil|table<string, string> nil until the first fetch of that dir finishes
M.get_status = function(dir)
  return cache[dir]
end

---A failed fetch is not the same as a clean tree: leave the directory unknown,
---tell the user once per failure spell, and retry after a short backoff.
---@param dir string
---@param backend string
---@param reason string
local function report_failure(dir, backend, reason)
  local first = retry_at[dir] == nil
  retry_at[dir] = vim.uv.now() + M.config.retry_ms
  local message = ("oil: %s failed in %s: %s"):format(backend, dir, vim.trim(reason))
  log.warn("%s", message)
  if first and M.config.notify_on_error then
    vim.schedule(function()
      vim.notify(message, vim.log.levels.WARN)
    end)
  end
  vim.schedule(M.render)
end

---Fetch the status of a directory.
---@param dir string
---@param force nil|boolean Refetch even if the last attempt failed just now
M.load = function(dir, force)
  if not M.config then
    return
  end
  tracked[dir] = true
  if inflight[dir] then
    return
  end
  if not force and retry_at[dir] and vim.uv.now() < retry_at[dir] then
    return
  end
  local backend = M.detect_backend(dir)
  if not backend then
    cache[dir] = {}
    return
  end
  inflight[dir] = true
  -- vim.system throws when the binary is missing, so a broken PATH or a
  -- vanished cwd must not take the oil listing down with it
  local spawned, spawn_err = pcall(
    vim.system,
    backend.cmd,
    { cwd = dir, text = true },
    function(res)
      inflight[dir] = nil
      if res.code ~= 0 then
        report_failure(dir, backend.name, res.stderr or ("exit code " .. res.code))
        return
      end
      retry_at[dir] = nil
      cache[dir] = aggregate.to_entries(backend.parse(res.stdout))
      vim.schedule(M.render)
    end
  )
  if not spawned then
    inflight[dir] = nil
    report_failure(dir, backend.name, tostring(spawn_err))
  end
end

---Refetch a directory whose status is already on screen. Nothing has been
---fetched for a directory the column never rendered, so there is nothing to
---refresh either.
---@param dir string
M.reload = function(dir)
  if cache[dir] == nil then
    return
  end
  M.load(dir, true)
end

---Forget every directory that has been fetched.
---@private
M.clear = function()
  cache = {}
  inflight = {}
  tracked = {}
  retry_at = {}
end

---Rerender the oil buffers showing statuses we already know.
M.render = function()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    -- oil deletes hidden buffers after cleanup_delay_ms, so re-check liveness
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.bo[bufnr].filetype == "oil" then
        local dir = require("oil").get_current_dir(bufnr)
        -- rerendering throws away unsaved edits; never do that behind the user's back
        if dir and cache[dir] and not vim.bo[bufnr].modified then
          require("oil.view").render_buffer_async(bufnr, { refetch = false })
        end
      end
    end
  end
end

---Refetch and redraw. Without a directory every directory the column has
---fetched is refetched.
---@param dir nil|string
M.refresh = function(dir)
  local dirs = dir and { dir } or vim.tbl_keys(tracked)
  for _, d in ipairs(dirs) do
    retry_at[d] = nil
    M.load(d, true)
  end
end

---The colors are copied out of the colorscheme, so they are re-derived whenever
---oil re-derives its own highlights.
M.define_highlights = function()
  if M.config then
    highlight.define(M.config.highlight)
  end
end

---@param opts oil.VcsOptions
M.setup = function(opts)
  M.config = opts

  if opts.highlight_filename then
    local config = require("oil.config")
    local has_column = false
    for _, def in ipairs(config.columns) do
      if require("oil.util").split_config(def) == "vcs" then
        has_column = true
        break
      end
    end
    if has_column and not config.view_options.highlight_filename then
      config.view_options.highlight_filename = M.highlight_filename
    end
  end

  enabled = {}
  for _, name in ipairs(opts.backends) do
    local backend = backends[name]
    if backend then
      enabled[#enabled + 1] = backend
    else
      vim.notify(("oil: unknown vcs backend '%s'"):format(name), vim.log.levels.WARN)
    end
  end

  local aug = vim.api.nvim_create_augroup("OilVcs", { clear = true })

  if opts.refresh_on_mutation then
    vim.api.nvim_create_autocmd("User", {
      desc = "Refetch the version control status after oil applies file operations",
      group = aug,
      pattern = "OilMutationComplete",
      callback = function()
        M.refresh()
      end,
    })
  end

  if opts.refresh_on_write then
    vim.api.nvim_create_autocmd("BufWritePost", {
      desc = "Refetch the version control status of directories that contain a written file",
      group = aug,
      callback = function(args)
        local path = vim.api.nvim_buf_get_name(args.buf)
        -- a write can change the status of every directory above it;
        -- oil.get_current_dir keeps a trailing slash, so compare prefixes directly
        for dir in pairs(tracked) do
          if path:sub(1, #dir) == dir then
            M.load(dir, true)
          end
        end
      end,
    })
  end
end

---Tint the filename with the same group the column uses. Shares the column's
---fetch: the first render kicks off a fetch and keeps OilDir/OilFile until
---the redraw after it lands.
---@param entry oil.Entry
---@param _ boolean
---@param _ boolean
---@param _ boolean
---@param bufnr integer
---@return nil|string
M.highlight_filename = function(entry, _, _, _, bufnr)
  if not M.config or entry.name == ".." then
    return nil
  end
  local dir = require("oil").get_current_dir(bufnr)
  if not dir then
    return nil
  end
  local status = cache[dir]
  if not status then
    M.load(dir)
    return nil
  end
  local spec = status[entry.name] and M.config.highlight[status[entry.name]]
  return spec and spec.group
end

---The column as registered with |oil.columns|. A column render has to be
---synchronous, so it answers from the cache and the fetch that fills it redraws
---the buffer once the answer lands.
---@type oil.ColumnDefinition
M.column = {
  render = function(entry, _, bufnr)
    local conf = M.config
    if not conf then
      return ""
    end
    local name = entry[FIELD_NAME]
    if name == ".." then
      return ""
    end
    local dir = require("oil").get_current_dir(bufnr)
    if not dir then
      return ""
    end
    local status = cache[dir]
    if not status then
      M.load(dir)
      return ""
    end
    local code = status[name]
    if not code then
      return ""
    end
    local spec = conf.highlight[code]
    return { conf.symbols[code] or code, spec and spec.group }
  end,

  -- oil parses every line of the buffer, so consume the column's own text
  parse = function(line)
    return line:match("^(%S+)%s+(.*)$")
  end,
}

return M
