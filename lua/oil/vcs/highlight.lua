local M = {}

---Copy the foreground out of a group the colorscheme already colors. `link`
---cannot add attributes, and the diff groups only carry a background, which
---makes a one character column unreadable on a normal listing line.
---@param config table<string, oil.VcsHighlight>
M.define = function(config)
  for _, spec in pairs(config) do
    local base = vim.api.nvim_get_hl(0, { name = spec.base, link = false })
    if base.fg then
      vim.api.nvim_set_hl(0, spec.group, { fg = base.fg, bold = not spec.plain })
    else
      -- nothing to copy from, at least keep the column visible
      vim.api.nvim_set_hl(0, spec.group, { link = spec.base })
    end
  end
end

return M
