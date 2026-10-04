-- Generate doc/oil.txt, doc/api.md and the markdown tables of contents
-- Run from the repo root: nvim --clean -l scripts/gendoc.lua [lint]
vim.opt.rtp:prepend(".")

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

local function is_blank(s)
  return s:match("^%s*$") ~= nil
end

local function indent(lines, amount)
  local ret = {}
  for _, line in ipairs(lines) do
    table.insert(ret, is_blank(line) and line or string.rep(" ", amount) .. line)
  end
  return ret
end

local function trim_blank(lines)
  while lines[1] == "" do
    table.remove(lines, 1)
  end
  while lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

local function read_lines(path)
  local lines = {}
  for line in io.lines(path) do
    table.insert(lines, line)
  end
  return lines
end

-- Lines strictly between the first line matching start_pat and the next matching end_pat
local function read_section(path, start_pat, end_pat)
  local ret, inside = {}, false
  for _, line in ipairs(read_lines(path)) do
    if inside then
      if line:match(end_pat) then
        return ret
      end
      table.insert(ret, line)
    elseif line:match(start_pat) then
      inside = true
    end
  end
  error("could not find section " .. start_pat .. " in " .. path)
end

-- Text wrapping, ported from Python's textwrap.wrap()

local function is_letter(c)
  return c:match("^[%a_]$") ~= nil
end

-- textwrap may break a word after a hyphen: "nvim-web-devicons" -> "nvim-", "web-", "devicons"
local function split_hyphens(word, out)
  local start = 1
  local function at(i)
    return i >= 1 and word:sub(i, i) or ""
  end
  for i = start + 1, #word do
    if at(i) == "-" and i > start then
      local before = (is_letter(at(i - 2)) and is_letter(at(i - 1)))
        or (is_letter(at(i - 3)) and at(i - 2) == "-" and is_letter(at(i - 1)))
      local after = is_letter(at(i + 1))
        and (is_letter(at(i + 2)) or (at(i + 2) == "-" and is_letter(at(i + 3))))
      if before and after then
        table.insert(out, word:sub(start, i))
        start = i + 1
      end
    end
  end
  table.insert(out, word:sub(start))
end

local function split_chunks(text)
  text = text:gsub("%s", " ")
  local chunks, i = {}, 1
  while i <= #text do
    local space = text:match("^ +", i)
    if space then
      table.insert(chunks, space)
      i = i + #space
    else
      local word = text:match("^[^ ]+", i)
      split_hyphens(word, chunks)
      i = i + #word
    end
  end
  return chunks
end

local function wrap(text, first_indent, sub_indent)
  first_indent = first_indent or 0
  sub_indent = sub_indent or first_indent
  local break_at_start = first_indent >= WIDTH
  if break_at_start then
    first_indent = sub_indent
  end
  local chunks = split_chunks(text)
  local lines, i = {}, 1
  while i <= #chunks do
    local prefix = string.rep(" ", #lines > 0 and sub_indent or first_indent)
    local width = WIDTH - #prefix
    if #lines > 0 and is_blank(chunks[i]) then
      i = i + 1
    end
    local cur, cur_len = {}, 0
    while i <= #chunks and cur_len + #chunks[i] <= width do
      table.insert(cur, chunks[i])
      cur_len = cur_len + #chunks[i]
      i = i + 1
    end
    -- A word longer than the whole line gets cut
    if i <= #chunks and #chunks[i] > width then
      local space_left = width < 1 and 1 or width - cur_len
      table.insert(cur, chunks[i]:sub(1, space_left))
      chunks[i] = chunks[i]:sub(space_left + 1)
    end
    if #cur > 0 and is_blank(cur[#cur]) then
      table.remove(cur)
    end
    if #cur > 0 then
      table.insert(lines, prefix .. table.concat(cur))
    end
  end
  if break_at_start then
    table.insert(lines, 1, "")
  end
  return lines
end

-- LuaCATS annotation parser (---@param, ---@class, ...)
-- Every parse_* function takes a string and a start position, and returns the
-- parsed value plus the position after it, or nil when the text doesn't match.

local function skip_ws(s, pos)
  return s:match("^[ \t]*()", pos)
end

-- A whole word: not followed (or preceded) by an identifier character
local function keyword(s, pos, kw)
  if
    s:sub(pos, pos + #kw - 1) == kw
    and not s:sub(pos + #kw, pos + #kw):match("[%w_$]")
    and not s:sub(pos - 1, pos - 1):match("[%w_$]")
  then
    return pos + #kw
  end
end

local function parse_name(s, pos)
  local name = s:match("^[%a_][%w_]*", pos)
  if name then
    return name, pos + #name
  end
end

-- From an opening bracket at pos to its matching closing one
local function balanced(s, pos, open, close)
  local depth = 0
  for i = pos, #s do
    local c = s:sub(i, i)
    if c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then
        return s:sub(pos, i), i + 1
      end
    end
  end
end

local LISTS = { "string[]", "integer[]", "number[]", "any[]", "boolean[]", "table[]" }
local PRIMITIVES = { "nil", "string", "integer", "boolean", "number", "table" }

local parse_type

local function parse_atom(s, pos)
  pos = skip_ws(s, pos)
  for _, kw in ipairs(LISTS) do
    local stop = keyword(s, pos, kw)
    if stop then
      return kw, stop
    end
  end
  -- table<K, V>
  local stop = keyword(s, pos, "table")
  if stop and s:sub(skip_ws(s, stop), skip_ws(s, stop)) == "<" then
    local key, p = parse_type(s, skip_ws(s, stop) + 1)
    p = key and skip_ws(s, p)
    if p and s:sub(p, p) == "," then
      local space = s:match("^[ \t]*", p + 1)
      local value, p2 = parse_type(s, p + 1 + #space)
      p2 = value and skip_ws(s, p2)
      if p2 and s:sub(p2, p2) == ">" then
        return "table<" .. key .. "," .. space .. value .. ">", p2 + 1
      end
    end
  end
  -- { key: type, ... }
  if s:sub(pos, pos) == "{" then
    local literal, p = balanced(s, pos, "{", "}")
    if literal then
      return literal:gsub("^{%s*", "{"):gsub("%s*}$", "}"), p
    end
  end
  -- fun(args): ret
  stop = keyword(s, pos, "fun")
  if stop and s:sub(skip_ws(s, stop), skip_ws(s, stop)) == "(" then
    local args, p = balanced(s, skip_ws(s, stop), "(", ")")
    if args then
      local ret = "fun" .. args
      local colon = skip_ws(s, p)
      if s:sub(colon, colon) == ":" then
        local space = s:match("^[ \t]*", colon + 1)
        local rtype, p2 = parse_type(s, colon + 1 + #space)
        if rtype then
          return ret .. ":" .. space .. rtype, p2
        end
      end
      return ret, p
    end
  end
  for _, kw in ipairs(PRIMITIVES) do
    stop = keyword(s, pos, kw)
    if stop then
      return kw, stop
    end
  end
  -- "quoted"
  local quoted = s:match('^"[^"]*"', pos)
  if quoted then
    return quoted, pos + #quoted
  end
  local number = s:match("^%d+", pos)
  if number then
    return number, pos + #number
  end
  stop = keyword(s, pos, "any")
  if stop then
    return "any", stop
  end
  -- dotted.name, dotted.name[]
  local dotted = s:match("^[%w_]+%.[%w_]+", pos)
  if dotted then
    local p = pos + #dotted
    local more = s:match("^%.[%w_]+", p)
    while more do
      dotted, p = dotted .. more, p + #more
      more = s:match("^%.[%w_]+", p)
    end
    if s:sub(p, p + 1) == "[]" then
      dotted, p = dotted .. "[]", p + 2
    end
    return dotted, p
  end
end

-- A union of atoms: string|nil|fun()
parse_type = function(s, pos)
  local first, p = parse_atom(s, pos)
  if not first then
    return
  end
  local parts = { first }
  while true do
    local bar = skip_ws(s, p)
    if s:sub(bar, bar) ~= "|" then
      break
    end
    local nxt, p2 = parse_atom(s, bar + 1)
    if not nxt then
      break
    end
    table.insert(parts, nxt)
    p = p2
  end
  return table.concat(parts, "|"), p
end

-- name? type desc
local function parse_param(s, pos)
  pos = skip_ws(s, pos)
  local name, p
  if s:sub(pos, pos + 2) == "..." then
    name, p = "...", pos + 3
  else
    name, p = parse_name(s, pos)
  end
  if not name then
    return
  end
  local optional = s:sub(skip_ws(s, p), skip_ws(s, p)) == "?"
  if optional then
    p = skip_ws(s, p) + 1
  end
  local ptype, p2 = parse_type(s, p)
  if not ptype then
    return
  end
  return {
    name = name,
    type = optional and "nil|" .. ptype or ptype,
    desc = s:sub(skip_ws(s, p2)),
    subparams = {},
  }
end

local function strip_comment(lines)
  return vim.tbl_map(function(line)
    return line:sub(4)
  end, lines)
end

local function parse_func(name, lines)
  lines = strip_comment(lines)
  local func = { name = name, summary = "", params = {}, returns = {}, note = "", example = "" }
  local i = 1
  if lines[1] and lines[1]:match("^[^@ \t].") then
    func.summary = lines[1]
    i = 2
  end
  while i <= #lines do
    local line = lines[i]
    local tag = line:match("^[ \t]*@(%w+)")
    local rest = line:gsub("^[ \t]*@%w+", "", 1)
    i = i + 1
    if tag == "param" then
      local param = parse_param(rest, 1)
      if not param then
        return
      end
      -- Fields of a table param, indented on the following lines
      while lines[i] and lines[i]:match("^%s") do
        local sub = parse_param(lines[i], 1)
        if not sub then
          return
        end
        table.insert(param.subparams, sub)
        i = i + 1
      end
      table.insert(func.params, param)
    elseif tag == "return" then
      local rtype, p = parse_type(rest, 1)
      if not rtype then
        return
      end
      table.insert(func.returns, { type = rtype, desc = rest:sub(skip_ws(rest, p)) })
    elseif (tag == "private" or tag == "deprecated") and rest:match("^%s*$") then
      func[tag] = true
    elseif tag == "example" or tag == "note" then
      local text = {}
      while lines[i] and lines[i]:match("^%s.") do
        table.insert(text, lines[i]:sub(2))
        i = i + 1
      end
      if #text == 0 then
        return
      end
      func[tag] = table.concat(text, "\n")
    elseif line ~= "" or table.concat(lines, "", i) ~= "" then
      -- Only blank lines may follow the last tag
      return
    end
  end
  return func
end

local SCOPES = { private = true, protected = true, package = true, public = true }

local function parse_field(s)
  local rest = s:match("^@field(.*)$")
  if not rest then
    return
  end
  local pos = skip_ws(rest, 1)
  if rest:sub(pos, pos) == "[" then
    local _, p = parse_type(rest, pos + 1)
    p = p and skip_ws(rest, p)
    if not p or rest:sub(p, p) ~= "]" then
      return
    end
    local ftype, p2 = parse_type(rest, p + 1)
    if ftype then
      return { type = ftype, desc = rest:sub(skip_ws(rest, p2)) }
    end
    return
  end
  local scope = rest:match("^(%a+)", pos)
  if scope and SCOPES[scope] and keyword(rest, pos, scope) then
    local field = parse_param(rest, pos + #scope)
    if field then
      field.public = scope == "public"
      return field
    end
  end
  local field = parse_param(rest, pos)
  if field then
    field.public = true
  end
  return field
end

local function parse_class(lines)
  lines = strip_comment(lines)
  local i = 1
  while lines[i] and not lines[i]:match("^@") do
    i = i + 1
  end
  local header = lines[i] and lines[i]:gsub("^@class%s+%(exact%)", "@class")
  local name, parent = (header or ""):match("^@class%s+([^%s:]+)(.*)$")
  if not name or not (parent:match("^%s*$") or parent:match("^%s*:%s*%S+%s*$")) then
    return
  end
  local class = { name = name, fields = {} }
  i = i + 1
  if lines[i] and lines[i]:match("^@opaque%s*$") then
    class.opaque = true
    i = i + 1
  end
  for j = i, #lines do
    local field = parse_field(lines[j])
    if not field then
      return
    end
    table.insert(class.fields, field)
  end
  if #class.fields > 0 then
    return class
  end
end

local function parse_alias(lines)
  lines = strip_comment(lines)
  local name = vim.split(vim.trim(lines[1]), "%s+")[2]
  local values = {}
  for j = 2, #lines do
    local value, rest = lines[j]:match("^| '([^']+)'(.*)$")
    local desc = rest and (rest == "" and "" or rest:match("^ # (.+)$"))
    if not desc then
      return
    end
    table.insert(values, { value = value, desc = desc })
  end
  if #values > 0 then
    return { name = name, values = values }
  end
end

-- Group consecutive "---" lines and parse each group based on the line after it
local function parse_file(path)
  local file = { functions = {}, classes = {}, aliases = {} }
  local chunk = {}
  local function flush(next_line)
    local tags = {}
    for _, line in ipairs(chunk) do
      local tag = line:match("^%-%-%-(@[%w_]+)")
      if tag then
        tags[tag] = true
      end
    end
    local fn = next_line
      and (next_line:match("^M%.([%w_]+)%s*=") or next_line:match("^function ([A-Z][%w_:%.]*)%s*%("))
    -- A parse error (nil) skips the item, like the Python version did
    if fn and (tags["@param"] or tags["@return"] or next(tags) == nil) then
      file.functions[#file.functions + 1] = parse_func(fn, chunk)
    elseif tags["@class"] then
      file.classes[#file.classes + 1] = parse_class(chunk)
    elseif tags["@alias"] then
      file.aliases[#file.aliases + 1] = parse_alias(chunk)
    end
    chunk = {}
  end
  for _, line in ipairs(read_lines(path)) do
    if vim.startswith(line, "---") then
      table.insert(chunk, line)
    elseif #chunk > 0 then
      flush(line)
    end
  end
  if #chunk > 0 then
    flush(nil)
  end
  return file
end

local function parse_directory(dir)
  local types = { files = {}, classes = {}, aliases = {} }
  for relpath, kind in vim.fs.dir(dir, { depth = math.huge }) do
    if kind == "file" and vim.endswith(relpath, ".lua") then
      local file = parse_file(dir .. "/" .. relpath)
      types.files[relpath] = file
      for _, class in ipairs(file.classes) do
        types.classes[class.name] = class
      end
      for _, alias in ipairs(file.aliases) do
        types.aliases[alias.name] = alias
      end
    end
  end
  return types
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

local NO_TYPES = { classes = {}, aliases = {} }

local function rstrip(s)
  return (s:gsub("%s+$", ""))
end

local function lstrip(s)
  return (s:gsub("^%s+", ""))
end

local function strip_nil(t)
  return vim.startswith(t, "nil|") and t:sub(5) or t
end

-- Column width for names: the longest one up to `limit` chars, or 8 if none fits
local function name_width(names, limit)
  local width
  for _, name in ipairs(names) do
    if #name <= limit then
      width = math.max(width or 0, #name)
    end
  end
  return (width or 8) + 1
end

-- `line` followed by the wrapped description, aligned after it
local function with_desc(line, desc, sub_indent)
  local lines = wrap(desc, #line, sub_indent)
  if #lines == 0 then
    return { rstrip(line) }
  elseif lines[1] == "" then
    lines[1] = rstrip(line)
  else
    lines[1] = line .. lstrip(lines[1])
  end
  return lines
end

-- A table param expands into its own params: inline ones, or the fields of its class
local function subparams(param, types)
  if param.subparams and #param.subparams > 0 then
    return param.subparams
  end
  local class = types.classes[strip_nil(param.type)]
  local ret = {}
  if class and not class.opaque then
    for _, field in ipairs(class.fields) do
      if field.name and field.public then
        table.insert(ret, field)
      end
    end
  end
  return ret
end

local function format_alias_values(values, ind)
  local width = name_width(
    vim.tbl_map(function(v)
      return v.value
    end, values),
    12
  )
  local lines = {}
  for _, val in ipairs(values) do
    local line = string.rep(" ", ind) .. "`" .. val.value .. "`" .. string.rep(" ", width - #val.value)
    vim.list_extend(lines, with_desc(line, val.desc, math.min(#line - 2, width + ind)))
  end
  return lines
end

local function format_params(params, types, ind)
  local width = name_width(
    vim.tbl_map(function(p)
      return p.name
    end, params),
    16
  )
  local lines = {}
  for _, param in ipairs(params) do
    local prefix = string.rep(" ", ind)
      .. "{"
      .. param.name
      .. "}"
      .. string.rep(" ", width - #param.name - 1)
      .. " "
    local line = prefix .. "`" .. param.type .. "` "
    vim.list_extend(lines, with_desc(line, param.desc, math.min(#prefix, width + ind + 2)))
    local sub = subparams(param, types)
    if #sub > 0 then
      vim.list_extend(lines, format_params(sub, types, ind + 4))
    end
    local alias = types.aliases[strip_nil(param.type)]
    if alias then
      vim.list_extend(lines, format_alias_values(alias.values, ind + 4))
    end
  end
  return lines
end

local function format_returns(returns, ind)
  local lines = {}
  for _, ret in ipairs(returns) do
    local line = string.rep(" ", ind) .. "`" .. ret.type .. "` "
    vim.list_extend(lines, with_desc(line, ret.desc, ind))
  end
  return lines
end

local function render_api(project, funcs, types)
  local lines = {}
  for _, func in ipairs(funcs) do
    if not func.private and not func.deprecated then
      local args = vim.tbl_map(function(p)
        return "{" .. p.name .. "}"
      end, func.params)
      local signature = func.name .. "(" .. table.concat(args, ", ") .. ")"
      if #func.returns > 0 then
        local rtypes = vim.tbl_map(function(r)
          return r.type
        end, func.returns)
        signature = signature .. ": " .. table.concat(rtypes, ", ")
      end
      table.insert(lines, leftright(signature, "*" .. project .. "." .. func.name .. "*"))
      vim.list_extend(lines, wrap(func.summary, 4))
      table.insert(lines, "")
      if #func.params > 0 then
        table.insert(lines, "    Parameters:")
        vim.list_extend(lines, format_params(func.params, types, 6))
      end
      if vim.iter(func.returns):any(function(r)
        return r.desc ~= ""
      end) then
        table.insert(lines, "    Returns:")
        vim.list_extend(lines, format_returns(func.returns, 6))
      end
      if func.note ~= "" then
        vim.list_extend(lines, { "", "    Note:" })
        vim.list_extend(lines, indent(vim.split(func.note, "\n"), 6))
      end
      if func.example ~= "" then
        vim.list_extend(lines, { "", "    Examples: >lua" })
        vim.list_extend(lines, indent(vim.split(func.example, "\n"), 6))
        table.insert(lines, "<")
      end
      table.insert(lines, "")
    end
  end
  return trim_blank(lines)
end

local OPTIONS = [[

skip_confirm_for_simple_edits                  *oil.skip_confirm_for_simple_edits*
    type: `boolean` default: `false`
    Before performing filesystem operations, Oil displays a confirmation popup to ensure
    that all operations are intentional. When this option is `true`, the popup will be
    skipped if the operations:
        * contain no deletes
        * contain no cross-adapter moves or copies (e.g. from local to ssh)
        * contain at most one copy or move
        * contain at most five creates

prompt_save_on_select_new_entry              *oil.prompt_save_on_select_new_entry*
    type: `boolean` default: `true`
    There are two cases where this option is relevant:
    1. You copy a file to a new location, then you select it and make edits before
       saving.
    2. You copy a directory to a new location, then you enter the directory and make
       changes before saving.

    In case 1, when you edit the file you are actually editing the original file because
    oil has not yet moved/copied it to its new location. This means that the original
    file will, perhaps unexpectedly, also be changed by any edits you make.

    Case 2 is similar; when you edit the directory you are again actually editing the
    original location of the directory. If you add new files, those files will be
    created in both the original location and the copied directory.

    When this option is `true`, Oil will prompt you to save before entering a file or
    directory that is pending within oil, but does not exist on disk.]]

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

local function config_body()
  local lines = { ">lua", '    require("oil").setup({' }
  vim.list_extend(lines, indent(read_section("lua/oil/config.lua", "^local default_config =", "^}$"), 4))
  vim.list_extend(lines, { "    })", "<" })
  return lines
end

local COMMANDS = [[
    Open the file browser on {dir}. Without an argument, the directory of the
    current buffer is used; when the current buffer is a file, its parent
    directory is. `:OMO` is a short alias for the same command.

    The usual command modifiers work (`:vertical`, `:tab`, ...), and a count
    sets the window height when the listing is opened in a split. Arguments:
        --float     Open in a floating window (|oil.open_float()|)
        --trash     Browse the trash (|oil-trash|)
        --preview   Open with the preview window
        --progress  Reopen the progress window of a running mutation]]

local function commands_body()
  local lines = {
    leftright(":OhMyOil [--float|--trash|--preview] [dir]", "*:OhMyOil*"),
    leftright(":OMO [--float|--trash|--preview] [dir]", "*:OMO*"),
  }
  return vim.list_extend(lines, vim.split(COMMANDS, "\n"))
end

local UNIVERSAL = {
  {
    name = "highlight",
    type = "string|fun(value: string): string",
    desc = "Highlight group, or function that returns a highlight group",
  },
  { name = "align", type = '"left"|"center"|"right"', desc = "Text alignment within the column" },
}
local TIME = {
  { name = "format", type = "string", desc = "Format string (see :help strftime)" },
}

local COLUMNS = {
  {
    name = "type",
    adapters = "*",
    sortable = true,
    summary = "The type of the entry (file, directory, link, etc)",
    params = vim.list_extend(vim.deepcopy(UNIVERSAL), {
      { name = "icons", type = "table<string, string>", desc = "Mapping of entry type to icon" },
    }),
  },
  {
    name = "icon",
    adapters = "*",
    summary = "An icon for the entry's type (requires nvim-web-devicons)",
    params = vim.list_extend(vim.deepcopy(UNIVERSAL), {
      {
        name = "default_file",
        type = "string",
        desc = "Fallback icon for files when nvim-web-devicons returns nil",
      },
      { name = "directory", type = "string", desc = "Icon for directories" },
      {
        name = "add_padding",
        type = "boolean",
        desc = "Set to false to remove the extra whitespace after the icon",
      },
    }),
  },
  { name = "size", adapters = "files, ssh, s3", sortable = true, summary = "The size of the file", params = UNIVERSAL },
  {
    name = "permissions",
    adapters = "files, ssh",
    editable = true,
    summary = "Access permissions of the file",
    params = UNIVERSAL,
  },
  {
    name = "ctime",
    adapters = "files",
    sortable = true,
    summary = "Change timestamp of the file",
    params = vim.list_extend(vim.deepcopy(UNIVERSAL), TIME),
  },
  {
    name = "mtime",
    adapters = "files",
    sortable = true,
    summary = "Last modified time of the file",
    params = vim.list_extend(vim.deepcopy(UNIVERSAL), TIME),
  },
  {
    name = "atime",
    adapters = "files",
    sortable = true,
    summary = "Last access time of the file",
    params = vim.list_extend(vim.deepcopy(UNIVERSAL), TIME),
  },
  {
    name = "birthtime",
    adapters = "files, s3",
    sortable = true,
    summary = "The time the file was created",
    params = vim.list_extend(vim.deepcopy(UNIVERSAL), TIME),
  },
  {
    name = "vcs",
    adapters = "files",
    summary = "Version control status of the entry (:help oil-vcs)",
    params = { UNIVERSAL[2] },
  },
}

local function columns_body()
  local lines = wrap(
    'Columns can be specified as a string to use default arguments (e.g. `"icon"`), or as a table to pass parameters (e.g. `{"size", highlight = "Special"}`)'
  )
  table.insert(lines, "")
  for _, col in ipairs(COLUMNS) do
    table.insert(lines, leftright(col.name, "*column-" .. col.name .. "*"))
    vim.list_extend(lines, wrap("Adapters: " .. col.adapters, 4))
    if col.sortable then
      vim.list_extend(lines, wrap("Sortable: this column can be used in view_props.sort", 4))
    end
    if col.editable then
      vim.list_extend(lines, wrap("Editable: this column is read/write", 4))
    end
    vim.list_extend(lines, wrap(col.summary, 4))
    vim.list_extend(lines, { "", "    Parameters:" })
    vim.list_extend(lines, format_params(col.params, NO_TYPES, 6))
    table.insert(lines, "")
  end
  return trim_blank(lines)
end

local VCS = [[
Oil can show the version control status of each entry in the listing.
The status comes from the version control system that owns the directory: jj
or git out of the box. Add the column to the listing to enable it:
>lua
    require("oil").setup({
      columns = { "icon", "vcs", "mtime" },
    })
<
Every entry gets one character:
    M  modified
    A  added
    D  deleted
    R  renamed
    C  copied
    ?  untracked
    !  ignored
    -  clean

A directory carries the most severe status of the files inside it, so a
directory whose contents changed is visible without entering it. Until the
first status of a directory arrives, its entries show the same `-` placeholder
that oil draws for an empty column; the listing is redrawn once it does.

The options live in the `vcs` table of |oil-config|. On top of those, the
column accepts `align` like any other column (|oil-columns|):
>lua
    require("oil").setup({
      columns = { { "vcs", align = "right" } },
      vcs = { symbols = { M = "~", ["?"] = "!" } },
    })
<]]
local VCS_BACKENDS = [[

A backend knows how to ask one version control system for the changes in a
directory. `vcs.backends` lists the backends to try, in order, and the
directory's closest repository wins: a checkout nested inside another one
belongs to the inner one, and within one directory the configured order
decides. The default is `{"jj", "git"}`.

A backend is a table:
>lua
    ---@class oil.VcsBackend
    ---@field name string
    ---@field cmd string[]  -- run with the listed directory as cwd
    ---@field detect fun(dir: string): boolean  -- true when dir itself holds the marker
    ---@field parse fun(stdout: string): oil.VcsChange[]
<
`parse` returns a list of `{ path, code }` with paths relative to the listed
directory. Paths outside the directory are dropped, and anything deeper is
reported against the entry that contains it. `detect` is asked about one
directory at a time while walking up towards the filesystem root. Register a
backend and name it in the option to use it:
>lua
    require("oil.vcs").register_backend({
      name = "svn",
      cmd = { "svn", "status", "." },
      detect = function(dir)
        return vim.uv.fs_stat(vim.fs.joinpath(dir, ".svn")) ~= nil
      end,
      parse = function(stdout)
        local changes = {}
        for _, line in ipairs(vim.split(stdout, "\n", { plain = true })) do
          local code, path = line:match("^(%a)%s+(.+)$")
          if code then
            changes[#changes + 1] = { path = path, code = code }
          end
        end
        return changes
      end,
    })
<]]
local VCS_HIGHLIGHTS = [[

Each status code has a highlight group. The foreground is copied from a
group that the colorscheme already colors, because `link` cannot add
attributes and the diff groups only carry a background:
    code  group                color copied from
    M     OilVcsModified       DiagnosticWarn
    A     OilVcsAdded          Added
    D     OilVcsDeleted        Removed
    R     OilVcsRenamed        Changed
    C     OilVcsCopied         Changed
    ?     OilVcsUntracked      DiagnosticHint
    !     OilVcsIgnored        Comment (not bold)

Override or add codes with the `highlight` option of the `vcs` table:
>lua
    require("oil").setup({
      vcs = {
        highlight = {
          M = { group = "OilVcsModified", base = "DiffChange", plain = true },
        },
      },
    })
<
Set `vcs.highlight_filename` to tint the filename itself with the same group
as the column (clean entries keep `OilFile`/`OilDir`). It needs the `vcs`
column, and a user `view_options.highlight_filename` wins:
>lua
    require("oil").setup({
      columns = { "icon", "vcs", "mtime" },
      vcs = { highlight_filename = true },
    })
<
Colors are re-derived whenever the colorscheme changes.]]
local VCS_API = [[

oil.vcs.refresh({dir})                                  *oil.vcs.refresh()*
    Refetch and redraw. Without an argument, every directory the column has
    fetched is refetched.

oil.vcs.get_status({dir})                            *oil.vcs.get_status()*
    The status of a directory as `{ [entry name] = code }`, or nil until the
    first fetch of that directory finishes.]]
local VCS_LIMITATIONS = [[

- The column is read-only, so it cannot be sorted by.
- Only the local filesystem adapter is supported. Remote schemes have no
  working copy to inspect.
- Ignored files only show up if the backend reports them (git needs
  `--ignored`, which oil does not pass).
- Rename detection is whatever the backend reports. jj summarises a rename as
  one entry, git only when it notices the rename.]]

local function vcs_body()
  local lines = vim.split(VCS, "\n")
  for _, sub in ipairs({
    { "Backends", "oil-vcs-backends", VCS_BACKENDS },
    { "Highlights", "oil-vcs-highlights", VCS_HIGHLIGHTS },
    { "API", "oil-vcs-api", VCS_API },
    { "Limitations", "oil-vcs-limitations", VCS_LIMITATIONS },
  }) do
    table.insert(lines, "")
    table.insert(lines, leftright(sub[1], "*" .. sub[2] .. "*"))
    vim.list_extend(lines, vim.split(sub[3], "\n"))
  end
  return lines
end

local KEYMAPS = [[
The `keymaps` option in `oil.setup` allow you to create mappings using all the same parameters as |vim.keymap.set|.
>lua
    keymaps = {
        -- Mappings can be a string
        ["~"] = "<cmd>edit $HOME<CR>",
        -- Mappings can be a function
        ["gd"] = function()
            require("oil").set_columns({ "icon", "permissions", "size", "mtime" })
        end,
        -- You can pass additional opts to vim.keymap.set by using
        -- a table with the mapping as the first element.
        ["<leader>ff"] = {
            function()
                require("telescope.builtin").find_files({
                    cwd = require("oil").get_current_dir()
                })
            end,
            mode = "n",
            nowait = true,
            desc = "Find files in the current directory"
        },
        -- Mappings that are a string starting with "actions." will be
        -- one of the built-in actions, documented below.
        ["`"] = "actions.tcd",
        -- Some actions have parameters. These are passed in via the `opts` key.
        ["<leader>:"] = {
            "actions.open_cmdline",
            opts = {
                shorten_path = true,
                modify = ":h",
            },
            desc = "Open the command line with the current directory as an argument",
        },
    }]]

local function actions_body()
  local lines = vim.split(KEYMAPS, "\n")
  table.insert(lines, "")
  vim.list_extend(
    lines,
    wrap(
      'Below are the actions that can be used in the `keymaps` section of config options. You can refer to them as strings (e.g. "actions.<action_name>") or you can use the functions directly with `require("oil.actions").action_name.callback()`'
    )
  )
  table.insert(lines, "")
  local actions = require("oil.actions")._get_actions()
  table.sort(actions, function(a, b)
    return a.name < b.name
  end)
  for _, action in ipairs(actions) do
    if not action.deprecated then
      table.insert(lines, leftright(action.name, "*actions." .. action.name .. "*"))
      vim.list_extend(lines, wrap(action.desc, 4))
      if action.parameters and next(action.parameters) then
        local params = {}
        for name, param in pairs(action.parameters) do
          table.insert(params, { name = name, type = param.type, desc = param.desc })
        end
        table.sort(params, function(a, b)
          return a.name < b.name
        end)
        vim.list_extend(lines, { "", "    Parameters:" })
        vim.list_extend(lines, format_params(params, NO_TYPES, 6))
      end
      table.insert(lines, "")
    end
  end
  return trim_blank(lines)
end

local function highlights_body()
  local lines = {}
  for _, hl in ipairs(require("oil")._get_highlights()) do
    if hl.desc then
      table.insert(lines, leftright(hl.name, "*hl-" .. hl.name .. "*"))
      vim.list_extend(lines, wrap(hl.desc, 4))
      table.insert(lines, "")
    end
  end
  return trim_blank(lines)
end

local TYPES = parse_directory("lua")
local API_FUNCS = TYPES.files["oil/init.lua"].functions

local function api_body()
  return render_api("oil", API_FUNCS, TYPES)
end

local sections = {
  { name = "config", tag = "oil-config", body = config_body() },
  { name = "options", tag = "oil-options", body = vim.split(OPTIONS, "\n") },
  { name = "Commands", tag = "oil-commands", body = commands_body() },
  { name = "API", tag = "oil-api", body = api_body() },
  { name = "Columns", tag = "oil-columns", body = columns_body() },
  { name = "Version control column", tag = "oil-vcs", body = vcs_body() },
  { name = "Actions", tag = "oil-actions", body = actions_body() },
  { name = "Highlights", tag = "oil-highlights", body = highlights_body() },
  { name = "Trash", tag = "oil-trash", body = vim.split(TRASH, "\n") },
}

local prefix = {
  "*oil.txt*",
  "*OhMyOil* *oh-my-oil* *oh-my-oil.nvim* *Oil* *oil* *oil.nvim*",
}

-- Markdown

local function write_lines(path, lines)
  local file = assert(io.open(path, "w"))
  file:write(table.concat(lines, "\n"), "\n")
  file:close()
end

-- Replace the lines between the first start_pat line and the next end_pat line
local function replace_section(path, start_pat, end_pat, new_lines)
  local before, after, state = {}, {}, "before"
  for _, line in ipairs(read_lines(path)) do
    if state == "before" then
      table.insert(before, line)
      if line:match(start_pat) then
        state = "inside"
      end
    elseif state == "inside" and line:match(end_pat) then
      state = "after"
    end
    if state == "after" then
      table.insert(after, line)
    end
  end
  if state ~= "after" then
    error("could not find section " .. start_pat .. " in " .. path)
  end
  write_lines(path, vim.list_extend(vim.list_extend(before, new_lines), after))
end

local function md_anchor(title)
  return (title:lower():gsub("%s", "-"):gsub("[^%w_%-]", ""))
end

-- "## Title" is level 0, "### Title" level 1, ...
local function md_toc(path, max_level)
  local lines = { "" }
  for _, line in ipairs(read_lines(path)) do
    local hashes, title = line:match("^#(#+) (.+)$")
    if hashes and #hashes - 1 < max_level then
      local link = "[" .. title .. "](#" .. md_anchor(title) .. ")"
      table.insert(lines, string.rep("  ", #hashes - 1) .. "- " .. link)
    end
  end
  table.insert(lines, "")
  return lines
end

local function update_md_toc(path, max_level)
  replace_section(path, "^<!%-%- TOC %-%->$", "^<!%-%- /TOC %-%->$", md_toc(path, max_level or math.huge))
end

-- |target| -> target
local function strip_vimdoc_links(s)
  return (s:gsub("()|([^|]+)|()", function(start, target, stop)
    if not s:sub(start - 1, start - 1):match("[%w_]") and not s:sub(stop, stop):match("[%w_]") then
      return target
    end
  end))
end

local function md_table(rows, cols)
  local widths = {}
  for _, col in ipairs(cols) do
    widths[col] = math.max(3, #col)
    for _, row in ipairs(rows) do
      widths[col] = math.max(widths[col], #(row[col] or ""))
    end
  end
  local function format_row(cells)
    local padded = {}
    for _, col in ipairs(cols) do
      local cell = cells[col] or ""
      table.insert(padded, cell .. string.rep(" ", widths[col] - #cell))
    end
    return "| " .. table.concat(padded, " | ") .. " |"
  end
  local header, sep = {}, {}
  for _, col in ipairs(cols) do
    header[col] = col
    sep[col] = string.rep("-", widths[col])
  end
  local lines = { format_row(header), format_row(sep) }
  for _, row in ipairs(rows) do
    table.insert(lines, format_row(row))
  end
  return lines
end

local function params_to_rows(params, types, prefix)
  prefix = prefix or ""
  local rows = {}
  for _, param in ipairs(params) do
    table.insert(rows, {
      Param = prefix .. param.name,
      Type = "`" .. param.type:gsub("|", "\\|") .. "`",
      Desc = strip_vimdoc_links(param.desc),
    })
    vim.list_extend(rows, params_to_rows(subparams(param, types), types, prefix .. ">"))
    local alias = types.aliases[strip_nil(param.type)]
    for _, val in ipairs(alias and alias.values or {}) do
      table.insert(rows, { Type = "`" .. val.value .. "`", Desc = strip_vimdoc_links(val.desc) })
    end
  end
  return rows
end

local function render_md_api(funcs, types)
  local lines = { "" }
  for _, func in ipairs(funcs) do
    if not func.private and not func.deprecated then
      local args = vim.tbl_map(function(p)
        return p.name
      end, func.params)
      local signature = func.name .. "(" .. table.concat(args, ", ") .. ")"
      vim.list_extend(lines, { "## " .. signature, "" })
      if #func.returns > 0 then
        local rtypes = vim.tbl_map(function(r)
          return r.type
        end, func.returns)
        signature = signature .. ": " .. table.concat(rtypes, ", ")
      end
      if func.summary ~= "" then
        vim.list_extend(lines, { "`" .. signature .. "` \\", func.summary, "" })
      else
        vim.list_extend(lines, { "`" .. signature .. "`", "" })
      end
      if #func.params > 0 then
        vim.list_extend(lines, md_table(params_to_rows(func.params, types), { "Param", "Type", "Desc" }))
      end
      if vim.iter(func.returns):any(function(r)
        return r.desc ~= ""
      end) then
        vim.list_extend(lines, { "", "Returns:", "" })
        local rows = vim.tbl_map(function(r)
          return { Type = r.type, Desc = r.desc }
        end, func.returns)
        vim.list_extend(lines, md_table(rows, { "Type", "Desc" }))
      end
      if func.note ~= "" then
        vim.list_extend(lines, { "", "**Note:**", "<pre>", func.note, "</pre>" })
      end
      if func.example ~= "" then
        vim.list_extend(lines, { "", "**Examples:**", "```lua", func.example, "```" })
      end
      table.insert(lines, "")
    end
  end
  table.insert(lines, "")
  return lines
end

-- Every relative link in the markdown files must point to an existing file and heading

local function has_anchor(path, anchor)
  for _, line in ipairs(read_lines(path)) do
    local _, title = line:match("^#(#+) (.+)$")
    title = title and (title:match("^%[([^%]]+)%]%([^%)]+%)") or title)
    if title and md_anchor(title) == anchor then
      return true
    end
  end
  return false
end

local function lint_md_links(paths)
  local errors = {}
  for _, path in ipairs(paths) do
    local in_code = false
    for _, line in ipairs(read_lines(path)) do
      if line:match("^```") then
        in_code = not in_code
      elseif not in_code then
        for link in line:gmatch("%[[^%]]+%]%(([^%)]+)%)") do
          if not link:match("^<?http") then
            local target, anchor = unpack(vim.split(link, "#", { plain = true }))
            target = target == "" and path or vim.fs.joinpath(vim.fs.dirname(path), target)
            if not vim.uv.fs_stat(target) then
              table.insert(errors, path .. " invalid link: " .. link)
            elseif anchor and not has_anchor(target, anchor) then
              table.insert(errors, path .. " invalid link anchor: " .. link)
            end
          end
        end
      end
    end
  end
  return errors
end

if arg[1] == "lint" then
  local errors = lint_md_links(vim.list_extend({ "README.md" }, vim.fn.glob("doc/*.md", false, true)))
  for _, err in ipairs(errors) do
    io.stdout:write(err, "\n")
  end
  os.exit(#errors > 0 and 1 or 0)
end

replace_section("doc/api.md", "^<!%-%- API %-%->$", "^<!%-%- /API %-%->$", render_md_api(API_FUNCS, TYPES))
update_md_toc("doc/api.md", 1)
update_md_toc("README.md", 1)
update_md_toc("doc/recipes.md")
write_lines("doc/oil.txt", render_doc(prefix, "oh-my-oil", sections))
