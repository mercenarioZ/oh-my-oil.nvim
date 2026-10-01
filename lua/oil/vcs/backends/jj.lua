---@type oil.VcsBackend
return {
  name = "jj",
  cmd = { "jj", "diff", "--summary" },
  detect = function(dir)
    return vim.uv.fs_stat(vim.fs.joinpath(dir, ".jj")) ~= nil
  end,
  parse = function(stdout)
    local changes = {}
    for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
      -- "<CODE> path", a rename reads "R {old => new}"
      local code, path = line:match("^(%a) (.+)$")
      if code then
        if path:sub(1, 1) == "{" then
          path = path:match("=> ([^}]+)") or path
        end
        changes[#changes + 1] = { path = path, code = code }
      end
    end
    return changes
  end,
}
