local WIDTH = 80

local function vimlen(s)
  local len = #s
  for _, c in ipairs({ "*", "|", "`" }) do
    local count = select(2, s:gsub("%" .. c, ""))

    len = len - 2 * math.floor(count / 2)
  end

  return len
end

local function leftright(left, right)
  local spaces = math.max(1, WIDTH - vimlen(left) - vimlen(right))
  return left .. string.rep(" ", spaces) .. right
end

local function capitalize(s)
  return s:sub(1, 1):upper() .. s:sub(2):lower()
end

local function render_section(section)
  local lines = {
    string.rep("-", WIDTH),
    leftright(section.name:upper(), "*" .. section.tag .. "*"),
    "",
  }
  vim.list_extend(lines, section.body)
  table.insert(lines, "")
  return lines
end

local function toc_body(sections)
  local lines = {}

  for i, section in ipairs(sections) do
    local left = "  " .. i .. ". " .. capitalize(section.name)
    local tag_start = WIDTH - 4 - vimlen(section.tag)

    table.insert(lines, left .. string.rep(" ", tag_start - #left) .. "|" .. section.tag .. "|")
  end

  return lines
end

local function render_doc(prefix, project, sections)
  local lines = vim.list_extend({}, prefix)
  local toc = { name = "CONTENTS", tag = project .. "-contents", body = toc_body(sections) }
  vim.list_extend(lines, render_section(toc))
  for _, section in ipairs(sections) do
    vim.list_extend(lines, render_section(section))
  end
  table.insert(lines, string.rep("=", WIDTH))
  table.insert(lines, "vim:tw=80:ts=2:ft=help:norl:syntax=help:")
  return lines
end

local TRASH = [[

Oil has built-in support for using the system trash. When
`delete_to_trash = true`, any deleted files will be sent to the trash instead
of being permanently deleted. You can browse the trash for a directory using
the `toggle_trash` action (bound to `g\` by default). You can view all files
in the trash with `:OhMyOil --trash /`.

To restore files, simply move them from the trash to the desired destination,
the same as any other file operation. If you delete files from the trash they
will be permanently deleted (purged).

Linux:
    Oil supports the FreeDesktop trash specification.
    https://specifications.freedesktop.org/trash/1.0/
    All features should work.

Mac:
    Oil has limited support for MacOS due to the proprietary nature of the
    implementation. The trash bin can only be viewed as a single dir
    (instead of being able to see files that were trashed from a directory).

Windows:
    Oil supports the Windows Recycle Bin. All features should work.]]

local sections = {
  { name = "config", tag = "oil-config", body = {} },
  { name = "options", tag = "oil-options", body = {} },
  { name = "Commands", tag = "oil-commands", body = {} },
  { name = "API", tag = "oil-api", body = {} },
  { name = "Columns", tag = "oil-columns", body = {} },
  { name = "Version control column", tag = "oil-vcs", body = {} },
  { name = "Actions", tag = "oil-actions", body = {} },
  { name = "Highlights", tag = "oil-highlights", body = {} },
  { name = "Trash", tag = "oil-trash", body = vim.split(TRASH, "\n") },
}

local prefix = {
  "*oil.txt*",
  "*OhMyOil* *oh-my-oil* *oh-my-oil.nvim* *Oil* *oil* *oil.nvim*",
}

io.stdout:write(table.concat(render_doc(prefix, "oh-my-oil", sections), "\n"), "\n")
