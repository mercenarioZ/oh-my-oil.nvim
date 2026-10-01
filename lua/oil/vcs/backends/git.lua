---@param path string
---@return string
local function unquote(path)
  -- core.quotepath=false still quotes paths that contain tabs or newlines
  return (path:gsub('^"(.*)"$', "%1"):gsub('\\"', '"'):gsub("\\\\", "\\"))
end

---@type oil.VcsBackend
return {
  name = "git",
  cmd = { "git", "-c", "core.quotepath=false", "status", ".", "--short" },
  detect = function(dir)
    -- .git is a directory in a normal checkout, and a file in a worktree or submodule
    return vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) ~= nil
  end,
  parse = function(stdout)
    local changes = {}
    for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
      -- "<XY> path", a rename reads "R  old -> new"
      if #line > 3 and line:sub(3, 3) == " " then
        local xy, path = line:sub(1, 2), unquote(line:sub(4))
        local arrow = path:find(" -> ", 1, true)
        if arrow then
          path = path:sub(arrow + 4)
        end
        -- the worktree flag wins over the index flag: " M" and "MM" both mean modified
        local code = xy:sub(2, 2)
        if code == " " then
          code = xy:sub(1, 1)
        end
        changes[#changes + 1] = { path = path, code = code }
      end
    end
    return changes
  end,
}
