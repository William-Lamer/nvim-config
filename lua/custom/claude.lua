-- Explain errors and code with Claude Code in a popup, and chat with it in a vertical split.
-- A mode is { model = 'sonnet', effort = 'medium', lite = true }; model and effort go straight to the claude CLI.
-- Lite popups replace Claude Code's system prompt, tools and settings with a short prompt,
-- which cuts each call from ~13k to ~0.5k input tokens. They can't read other files.

local M = {}

local ROOT_MARKERS = {
  '.git',
  'Makefile',
  'CMakeLists.txt',
  'compile_commands.json',
  'compile_flags.txt',
  'Cargo.toml',
  'package.json',
  'pyproject.toml',
}
-- Lite popups send the whole file up to this size, otherwise only a window around the target
local LITE_FILE_LINES = 150
local LITE_WINDOW = 50
-- Compilers put the root cause first and crashes put it last, so long output keeps both ends
local OUTPUT_HEAD = 40
local OUTPUT_TAIL = 60

local LITE_SYSTEM_PROMPT = 'You help a computer science student understand errors and code from inside their editor. '
  .. 'Explain why things work or fail, not just the fix, but be concise: the answer is shown in a small popup. '
  .. 'Use short paragraphs or bullets and markdown code blocks. Aim for under 200 words unless the code truly needs more.'
local DEEP_APPEND_PROMPT = 'The answer is shown in a popup in the editor. Read other project files only if the answer depends on them.'

local ns = vim.api.nvim_create_namespace 'custom-claude'

-- Output of the most recent terminal job that exited with a non-zero status,
-- captured when it exits so it survives closing the terminal window.
local last_failed_run = nil
local chat = {}
local operator_mode = nil

local function is_file_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' and vim.api.nvim_buf_get_name(buf) ~= ''
end

local function project_root(buf)
  if is_file_buffer(buf) then
    return vim.fs.root(buf, ROOT_MARKERS) or vim.fs.dirname(vim.api.nvim_buf_get_name(buf))
  end
  local source = vim.b[buf].claude_source
  if source and is_file_buffer(source) then
    return project_root(source)
  end
  return vim.fn.getcwd()
end

-- Terminal buffer names look like term://{cwd}//{pid}:{cmd}
local function terminal_command(buf)
  return vim.api.nvim_buf_get_name(buf):match '^term://.-//%d+:(.*)$' or 'a command'
end

local function terminal_lines(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  while #lines > 0 and lines[#lines] == '' do
    table.remove(lines)
  end
  local omitted = #lines - OUTPUT_HEAD - OUTPUT_TAIL
  if omitted > 0 then
    local tail = vim.list_slice(lines, #lines - OUTPUT_TAIL + 1)
    lines = vim.list_slice(lines, 1, OUTPUT_HEAD)
    table.insert(lines, string.format('... (%d lines omitted) ...', omitted))
    vim.list_extend(lines, tail)
  end
  return table.concat(lines, '\n')
end

local function file_section(buf, mode, focus_first, focus_last)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local from, to = 1, #lines
  if mode.lite and #lines > LITE_FILE_LINES then
    from = math.max(1, (focus_first or 1) - LITE_WINDOW)
    to = math.min(#lines, (focus_last or focus_first or 1) + LITE_WINDOW)
  end
  local numbered = {}
  for i = from, to do
    table.insert(numbered, string.format('%4d  %s', i, lines[i]))
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local scope = (from == 1 and to == #lines) and 'full file' or string.format('lines %d-%d of %d', from, to, #lines)
  local ft = vim.bo[buf].filetype
  return string.format(
    'File %s (%s, may include unsaved changes):\n```%s\n%s\n```',
    name == '' and '[unnamed buffer]' or (vim.fs.relpath(project_root(buf), name) or name),
    scope,
    ft,
    table.concat(numbered, '\n')
  )
end

-- First line of buf that compiler or sanitizer output points at, like "main.c:14:5: error" or "in main main.c:14"
local function line_mentioned_in(output, buf)
  local basename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':t')
  return tonumber(output:match(vim.pesc(basename) .. ':(%d+)'))
end

local function format_diagnostics(diags)
  local out = {}
  for _, d in ipairs(diags) do
    local source = d.source and (d.source .. ': ') or ''
    table.insert(out, string.format('- line %d, col %d [%s] %s%s', d.lnum + 1, d.col + 1, vim.diagnostic.severity[d.severity], source, d.message))
  end
  return table.concat(out, '\n')
end

-- Returns { first, last, text } for the current visual selection and leaves visual mode.
-- text is only set for a selection within one line, so a single identifier can be explained.
local function visual_target()
  local mode = vim.fn.mode()
  local first, last = vim.fn.line 'v', vim.fn.line '.'
  if first > last then
    first, last = last, first
  end
  local text
  if mode == 'v' and first == last then
    text = table.concat(vim.fn.getregion(vim.fn.getpos 'v', vim.fn.getpos '.', { type = 'v' }), '\n')
  end
  vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'nx', false)
  return { first = first, last = last, text = text }
end

local function in_visual_mode()
  return vim.fn.mode():match '^[vV\22]' ~= nil
end

local function chat_is_running()
  if not (chat.buf and vim.api.nvim_buf_is_valid(chat.buf)) then
    return false
  end
  local job = vim.b[chat.buf].terminal_job_id
  return job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1
end

local function show_chat_window()
  vim.cmd 'botright vsplit'
  chat.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat.win, chat.buf)
  vim.api.nvim_win_set_width(chat.win, math.max(70, math.floor(vim.o.columns * 0.4)))
  vim.cmd.startinsert()
end

local function has_claude()
  if vim.fn.executable 'claude' == 1 then
    return true
  end
  vim.notify('claude is not on the PATH Neovim was started with', vim.log.levels.ERROR)
  return false
end

-- Sessions are stored per directory, so a resumed session must start in the same root.
local function start_chat(mode, root, extra_args)
  if chat.buf and vim.api.nvim_buf_is_valid(chat.buf) then
    vim.api.nvim_buf_delete(chat.buf, { force = true })
  end
  chat.buf = vim.api.nvim_create_buf(false, true)
  show_chat_window()
  local cmd = vim.list_extend({ 'claude', '--model', mode.model, '--effort', mode.effort }, extra_args or {})
  vim.fn.jobstart(cmd, { term = true, cwd = root })
  vim.b[chat.buf].claude_chat = true
end

function M.toggle_chat(mode)
  if chat.win and vim.api.nvim_win_is_valid(chat.win) then
    vim.api.nvim_win_hide(chat.win)
    chat.win = nil
  elseif chat_is_running() then
    show_chat_window()
  elseif has_claude() then
    start_chat(mode, project_root(vim.api.nvim_get_current_buf()))
  end
end

local function popup_command(mode)
  local cmd = {
    'claude',
    '-p',
    '--model',
    mode.model,
    '--effort',
    mode.effort,
    '--strict-mcp-config',
    '--disable-slash-commands',
    '--output-format',
    'stream-json',
    '--include-partial-messages',
    '--verbose',
  }
  if mode.lite then
    return vim.list_extend(cmd, { '--system-prompt', LITE_SYSTEM_PROMPT, '--tools', '', '--setting-sources', '' })
  end
  return vim.list_extend(cmd, { '--append-system-prompt', DEEP_APPEND_PROMPT, '--tools', 'Read,Grep,Glob' })
end

local function open_popup(title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].bufhidden = 'wipe'
  local width = math.min(100, math.floor(vim.o.columns * 0.7))
  local height = math.floor(vim.o.lines * 0.6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'center',
    footer = ' q close   c continue in chat ',
    footer_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].conceallevel = 2
  return buf
end

-- ctx is { title, prompt, focus = { buf, first, last } }. focus is highlighted while the popup is open.
local function run_popup(mode, ctx)
  if not has_claude() then
    return
  end
  local root = project_root(vim.api.nvim_get_current_buf())
  if ctx.focus then
    vim.api.nvim_buf_set_extmark(ctx.focus.buf, ns, ctx.focus.first - 1, 0, {
      end_row = ctx.focus.last - 1,
      end_col = #vim.api.nvim_buf_get_lines(ctx.focus.buf, ctx.focus.last - 1, ctx.focus.last, false)[1],
      hl_group = 'Visual',
      hl_eol = true,
    })
  end

  local buf = open_popup(mode.model .. ': ' .. ctx.title)
  local text, pending, session_id, done = '', '', nil, false

  local function render()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text == '' and '_Thinking..._' or text, '\n'))
    end
  end
  render()

  -- See `claude -p --output-format stream-json` for the event shapes
  local function handle_event(ev)
    if ev.type == 'system' and ev.session_id then
      session_id = ev.session_id
    elseif ev.type == 'result' and ev.is_error then
      text = text .. '\n\n**Error:** ' .. tostring(ev.result)
    elseif ev.type == 'result' and text == '' and type(ev.result) == 'string' then
      text = ev.result
    elseif ev.type == 'stream_event' then
      local e = ev.event
      if e.type == 'message_start' and text ~= '' then
        text = text .. '\n\n'
      elseif e.type == 'content_block_start' and e.content_block.type == 'tool_use' then
        text = text .. '`[' .. e.content_block.name .. ']` '
      elseif e.type == 'content_block_delta' and e.delta.type == 'text_delta' then
        text = text .. e.delta.text
      end
    end
  end

  -- stdout arrives in arbitrary chunks, so buffer until each full JSON line is in
  local function feed(data)
    pending = pending .. data
    for line in pending:gmatch '([^\n]*)\n' do
      local ok, ev = pcall(vim.json.decode, line)
      if ok and type(ev) == 'table' then
        handle_event(ev)
      end
    end
    pending = pending:match '[^\n]*$'
    render()
  end

  local job = vim.system(popup_command(mode), {
    cwd = root,
    stdin = ctx.prompt,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          feed(data)
        end)
      end
    end,
  }, function(res)
    vim.schedule(function()
      done = true
      if res.code ~= 0 and text == '' then
        text = '**claude exited with status ' .. res.code .. '**\n\n' .. (res.stderr or '')
        render()
      end
    end)
  end)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    once = true,
    callback = function()
      if not done then
        job:kill 'sigterm'
      end
      if ctx.focus and vim.api.nvim_buf_is_valid(ctx.focus.buf) then
        vim.api.nvim_buf_clear_namespace(ctx.focus.buf, ns, 0, -1)
      end
    end,
  })

  local function close()
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  vim.keymap.set('n', 'c', function()
    if not done or not session_id then
      vim.notify('Wait for the answer to finish first', vim.log.levels.INFO)
      return
    end
    close()
    -- The chat gets the full Claude Code setup even when the popup was lite
    start_chat(mode, root, { '--resume', session_id })
  end, { buffer = buf })
end

-- Picks which error to explain, most specific first. Returns a popup ctx or nil.
local function error_context(mode)
  local buf = vim.api.nvim_get_current_buf()
  local is_terminal = vim.bo[buf].buftype == 'terminal'

  -- The source file that terminal or run output belongs to, centered on the line the output mentions
  local function output_source_section(output, source)
    if not (source and is_file_buffer(source)) then
      return ''
    end
    local line = line_mentioned_in(output, source)
    return '\n\n' .. file_section(source, mode, line, line)
  end

  if in_visual_mode() then
    local target = visual_target()
    local selected = table.concat(vim.api.nvim_buf_get_lines(buf, target.first - 1, target.last, false), '\n')
    if is_terminal then
      return {
        title = 'selected output',
        prompt = 'Explain the errors in this output from `' .. terminal_command(buf) .. '`:\n```\n' .. selected .. '\n```' .. output_source_section(
          selected,
          vim.b[buf].claude_source
        ),
      }
    end
    local diags = vim.tbl_filter(function(d)
      return d.lnum + 1 >= target.first and d.lnum + 1 <= target.last
    end, vim.diagnostic.get(buf))
    local diag_text = #diags > 0 and ('Diagnostics in the selection:\n' .. format_diagnostics(diags) .. '\n\n') or ''
    return {
      title = string.format('bugs in lines %d-%d', target.first, target.last),
      focus = { buf = buf, first = target.first, last = target.last },
      prompt = string.format(
        'Find what is wrong with lines %d-%d, or say if they look correct.\n%s%s',
        target.first,
        target.last,
        diag_text,
        file_section(buf, mode, target.first, target.last)
      ),
    }
  end

  if is_terminal then
    local output = terminal_lines(buf)
    return {
      title = 'terminal output',
      prompt = 'Explain the errors in this output from `' .. terminal_command(buf) .. '`:\n```\n' .. output .. '\n```' .. output_source_section(
        output,
        vim.b[buf].claude_source
      ),
    }
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  local line_diags = vim.diagnostic.get(buf, { lnum = line - 1 })
  if #line_diags > 0 then
    return {
      title = 'error on line ' .. line,
      focus = { buf = buf, first = line, last = line },
      prompt = 'Explain these diagnostics on line ' .. line .. ':\n' .. format_diagnostics(line_diags) .. '\n\n' .. file_section(buf, mode, line, line),
    }
  end

  if last_failed_run and last_failed_run.root == project_root(buf) then
    local run = last_failed_run
    local run_source = output_source_section(run.output, run.source)
    return {
      title = 'last failed run',
      prompt = string.format(
        'I ran `%s` and it exited with status %d. Explain the error. Output:\n```\n%s\n```%s',
        run.command,
        run.status,
        run.output,
        run_source
      ),
    }
  end

  local file_diags = vim.diagnostic.get(buf, { severity = { min = vim.diagnostic.severity.WARN } })
  if #file_diags > 0 then
    local first = file_diags[1].lnum + 1
    return {
      title = 'file diagnostics',
      prompt = 'Explain these diagnostics:\n' .. format_diagnostics(file_diags) .. '\n\n' .. file_section(buf, mode, first, first),
    }
  end
end

function M.explain_error(mode)
  local ctx = error_context(mode)
  if not ctx then
    vim.notify('No errors here and no failed run. Select code in visual mode to look for bugs.', vim.log.levels.INFO)
    return
  end
  run_popup(mode, ctx)
end

-- target is { first, last, text }; text narrows the question to an exact expression or identifier.
local function explain_code(mode, target)
  local buf = vim.api.nvim_get_current_buf()
  local where = target.first == target.last and ('line ' .. target.first) or string.format('lines %d-%d', target.first, target.last)
  local subject = target.text and string.format('`%s` on %s', target.text, where) or where
  run_popup(mode, {
    title = 'explain ' .. (target.text and ('`' .. target.text .. '`') or where),
    focus = { buf = buf, first = target.first, last = target.last },
    prompt = string.format(
      'Explain %s: what it does and how it works. Focus on that part; the rest of the file is context.\n\n%s',
      subject,
      file_section(buf, mode, target.first, target.last)
    ),
  })
end

function M.explain_code(mode)
  if in_visual_mode() then
    explain_code(mode, visual_target())
  end
end

-- Used as 'operatorfunc', so <leader>cx can take any motion or text object, like ip or i{.
function M.operator(motion_type)
  local first, last = vim.fn.line "'[", vim.fn.line "']"
  local text
  if motion_type == 'char' and first == last then
    text = table.concat(vim.fn.getregion(vim.fn.getpos "'[", vim.fn.getpos "']", { type = 'v' }), '\n')
  end
  explain_code(operator_mode, { first = first, last = last, text = text })
end

function M.explain_code_operator(mode)
  operator_mode = mode
  vim.o.operatorfunc = "v:lua.require'custom.claude'.operator"
  return 'g@'
end

-- Node type names differ per language (function_definition in C and Python, function_item in Rust,
-- method_definition in JS), so match on the name instead of listing them.
local function enclosing_function()
  local ok, node = pcall(vim.treesitter.get_node)
  if not ok then
    return nil
  end
  while node do
    local t = node:type()
    if (t:match 'function' or t:match 'method') and not (t:match 'call' or t:match 'declarator' or t:match 'parameter') then
      local first, _, last, end_col = node:range()
      -- Some grammars end the node at column 0 of the line after it
      if end_col == 0 and last > first then
        last = last - 1
      end
      return { first = first + 1, last = last + 1 }
    end
    node = node:parent()
  end
end

function M.explain_function(mode)
  local target = enclosing_function()
  if not target then
    vim.notify('Cursor is not inside a function. Use <leader>cx with a motion or a visual selection.', vim.log.levels.INFO)
    return
  end
  explain_code(mode, target)
end

local group = vim.api.nvim_create_augroup('custom-claude', { clear = true })

-- Remember which file a terminal was opened from, so its output can be explained alongside that file.
vim.api.nvim_create_autocmd('TermOpen', {
  group = group,
  callback = function(ev)
    local alt = vim.fn.bufnr '#'
    if alt > 0 and is_file_buffer(alt) then
      vim.b[ev.buf].claude_source = alt
    end
  end,
})

vim.api.nvim_create_autocmd('TermClose', {
  group = group,
  callback = function(ev)
    if vim.b[ev.buf].claude_chat then
      return
    end
    local status = vim.v.event.status
    if status == 0 then
      last_failed_run = nil
    else
      last_failed_run = {
        command = terminal_command(ev.buf),
        status = status,
        output = terminal_lines(ev.buf),
        source = vim.b[ev.buf].claude_source,
        root = project_root(ev.buf),
      }
    end
  end,
})

return M
