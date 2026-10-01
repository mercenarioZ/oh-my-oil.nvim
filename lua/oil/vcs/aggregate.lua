local M = {}

-- Worst status wins when several files inside one entry changed
M.rank = { D = 6, M = 5, R = 4, C = 3, A = 2, ["?"] = 1, ["!"] = 0 }

---Collapse file paths reported by a backend into the entries of a single
---directory listing.
---@param changes oil.VcsChange[]
---@return table<string, string> entry name -> status code
M.to_entries = function(changes)
  local entries = {}
  for _, change in ipairs(changes) do
    local path = change.path
    -- a jj repository reports paths outside the directory being listed too
    if path ~= "" and path:sub(1, 3) ~= "../" then
      -- anything deeper is reported against the directory that contains it
      local name = path:match("^([^/]+)/") or path
      local previous = entries[name]
      if not previous or (M.rank[change.code] or 0) > (M.rank[previous] or 0) then
        entries[name] = change.code
      end
    end
  end
  return entries
end

return M
