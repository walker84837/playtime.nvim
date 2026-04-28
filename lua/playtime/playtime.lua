local M = {}

-- Configuration
M.idle_threshold = 2  -- Seconds of inactivity before considering paused
M.data_path = vim.fn.stdpath('data') .. '/playtime.json'

-- Data storage
M.data = {
  total_playtime = 0,
  lines_added = 0,
  lines_removed = 0,
  lines_edited = 0,
  days = {},
}

-- Buffer tracking
M.buffers = {}         -- buf -> { attached = true }
M.last_activity_ms = vim.uv.now()
M.last_check_ms = vim.uv.now()

-- Helpers
function M.format_time(seconds)
  local hours = math.floor(seconds / 3600)
  local remainder = seconds % 3600
  local minutes = math.floor(remainder / 60)
  local seconds = remainder % 60
  return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

function M.format_number(n)
  return tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
end

-- Data persistence
function M.load_data()
  local ok, contents = pcall(vim.fn.readfile, M.data_path)
  if ok and contents then
    local ok_parse, saved = pcall(vim.fn.json_decode, table.concat(contents, '\n'))
    if ok_parse and saved then
      local function num(v, default)
        return type(v) == 'number' and v or default
      end

      M.data.total_playtime = num(saved.total_playtime, M.data.total_playtime)
      M.data.lines_added = num(saved.lines_added, M.data.lines_added)
      M.data.lines_removed = num(saved.lines_removed, M.data.lines_removed)
      M.data.lines_edited = num(saved.lines_edited, M.data.lines_edited)

      if type(saved.days) == 'table' then
        for date, day_saved in pairs(saved.days) do
          if type(day_saved) == 'table' then
            M.data.days[date] = {
              playtime = num(day_saved.playtime, 0),
              lines_added = num(day_saved.lines_added, 0),
              lines_removed = num(day_saved.lines_removed, 0),
              lines_edited = num(day_saved.lines_edited, 0),
            }
          end
        end
      end
    end
  end
end

function M.save_data()
  local ok_json, json = pcall(vim.fn.json_encode, M.data)
  if not ok_json then
    vim.notify('Failed to encode playtime data', vim.log.levels.ERROR)
    return
  end

  local dir = vim.fn.fnamemodify(M.data_path, ':h')
  pcall(vim.fn.mkdir, dir, 'p')

  local ok_write, err = pcall(vim.fn.writefile, { json }, M.data_path)
  if not ok_write then
    vim.notify('Failed to save playtime data: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

-- Day data helper
function M.get_day_data(date)
  date = date or os.date('%Y-%m-%d')
  local day = M.data.days[date]
  if not day then
    day = {
      playtime = 0,
      lines_added = 0,
      lines_removed = 0,
      lines_edited = 0,
    }
    M.data.days[date] = day
  end
  return day
end

-- Stats update helper
function M.add_stats(added, removed, edited, date)
  added = added or 0
  removed = removed or 0
  edited = edited or 0

  M.data.lines_added = M.data.lines_added + added
  M.data.lines_removed = M.data.lines_removed + removed
  M.data.lines_edited = M.data.lines_edited + edited

  local day = M.get_day_data(date)
  day.lines_added = day.lines_added + added
  day.lines_removed = day.lines_removed + removed
  day.lines_edited = day.lines_edited + edited
end

-- Buffer attach (replaces setup_buffer + update_line_count)
function M.attach_buffer(bufnr)
  if M.buffers[bufnr] then return end
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end

  M.buffers[bufnr] = { attached = true }

  local ok, err = pcall(vim.api.nvim_buf_attach, bufnr, false, {
    on_lines = function(_, buf, _, firstline, old_lastline, new_lastline, _)
      local removed = old_lastline - firstline
      local added = new_lastline - firstline
      local edited = math.min(added, removed)
      added = added - edited
      removed = removed - edited

      M.add_stats(added, removed, edited)
      M.update_activity()
    end,
    on_detach = function(_, buf)
      M.buffers[buf] = nil
    end,
    on_reload = function(_, buf)
      -- Buffer reloaded (e.g. :edit), no action needed
    end
  })

  if not ok then
    M.buffers[bufnr] = nil
    vim.notify('Failed to attach to buffer ' .. bufnr .. ': ' .. tostring(err), vim.log.levels.WARN)
  end
end

-- Activity detection
function M.update_activity()
  M.last_activity_ms = vim.uv.now()
end

-- Timer
M.timer = vim.uv.new_timer()
M.timer:start(1000, 1000, vim.schedule_wrap(function()
  local now = vim.uv.now()
  local idle_ms = now - M.last_activity_ms

  if idle_ms <= M.idle_threshold * 1000 then
    local elapsed = math.floor((now - M.last_check_ms) / 1000)
    if elapsed > 0 then
      M.data.total_playtime = M.data.total_playtime + elapsed
      local day = M.get_day_data()
      day.playtime = day.playtime + elapsed
    end
  end

  M.last_check_ms = now
end))

-- Timer control
function M.stop_timer()
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil
  end
end

-- Report: build lines
function M.build_report_lines()
  local lines = {}

  table.insert(lines, 'Playtime Report')
  table.insert(lines, string.rep('═', 40))
  table.insert(lines, string.format('Total:    %s', M.format_time(M.data.total_playtime)))

  local total_added = M.data.lines_added
  local total_removed = M.data.lines_removed
  local total_edited = M.data.lines_edited
  local total_changed = total_added + total_removed + total_edited

  table.insert(lines, string.format('Lines:    +%s -%s ~%s (total changes: %s)',
    M.format_number(total_added),
    M.format_number(total_removed),
    M.format_number(total_edited),
    M.format_number(total_changed)))
  table.insert(lines, '')

  local days = {}
  for date, day_data in pairs(M.data.days) do
    table.insert(days, {
      date = date,
      playtime = day_data.playtime,
      lines_added = day_data.lines_added or 0,
      lines_removed = day_data.lines_removed or 0,
      lines_edited = day_data.lines_edited or 0,
    })
  end

  if #days > 0 then
    table.sort(days, function(a, b) return a.date < b.date end)
    table.insert(lines, 'Daily')
    table.insert(lines, string.rep('─', 40))

    for _, day in ipairs(days) do
      local added = day.lines_added
      local removed = day.lines_removed
      local edited = day.lines_edited
      local stats = string.format('+%s -%s ~%s',
        M.format_number(added),
        M.format_number(removed),
        M.format_number(edited))
      if added == 0 and removed == 0 and edited == 0 then
        stats = ''
      end
      table.insert(lines, string.format('%s  %s  %s',
        day.date,
        M.format_time(day.playtime),
        stats))
    end
  end

  table.insert(lines, '')
  table.insert(lines, string.rep('─', 40))
  table.insert(lines, 'q: close | y: copy')

  return lines
end

-- Report: open window
function M.open_report_window(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'playtime', { buf = buf })
  vim.api.nvim_buf_set_name(buf, 'Playtime report')

  local max_line_length = 0
  for _, line in ipairs(lines) do
    max_line_length = math.max(max_line_length, vim.fn.strdisplaywidth(line))
  end

  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local win_width = math.min(math.max(max_line_length, 45), ui.width - 4)
  local win_height = math.min(#lines + 2, ui.height - 4)

  local row = math.floor((ui.height - win_height) / 2)
  local col = math.floor((ui.width - win_width) / 2)

  local border = 'rounded'
  local winborder = vim.opt.winborder:get()
  if type(winborder) == 'string' and winborder ~= '' then
    border = winborder
  elseif type(winborder) == 'table' and #winborder > 0 then
    border = winborder
  end

  local win_opts = {
    relative = 'editor',
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    border = border,
    title = { { ' Playtime ', 'Title' } },
    title_pos = 'center',
    style = 'minimal',
  }
  local win = vim.api.nvim_open_win(buf, true, win_opts)

  vim.api.nvim_set_option_value('wrap', false, { win = win })
  vim.api.nvim_set_option_value('number', false, { win = win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = win })
  vim.api.nvim_set_option_value('cursorline', true, { win = win })
  vim.api.nvim_set_option_value('statusline', '', { win = win })

  vim.keymap.set('n', 'q', function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, silent = true })

  vim.keymap.set('n', 'y', function()
    M.copy_summary()
    vim.notify('Summary copied!', vim.log.levels.INFO, { title = 'Playtime' })
  end, { buffer = buf, silent = true })

  return win
end

-- Report: copy summary
function M.copy_summary()
  local summary = string.format('Playtime: %s | +%s -%s ~%s',
    M.format_time(M.data.total_playtime),
    M.format_number(M.data.lines_added),
    M.format_number(M.data.lines_removed),
    M.format_number(M.data.lines_edited))
  local reg = vim.fn.has('clipboard') == 1 and '+' or '"'
  vim.fn.setreg(reg, summary)
end

-- Report: echo summary
function M.show_summary_echo()
  local today = os.date('%Y-%m-%d')
  local today_data = M.get_day_data(today)

  vim.api.nvim_echo({
    { 'Playtime Summary:\n' },
    { ' Total: ' .. M.format_time(M.data.total_playtime) .. '\n' },
    { ' Lines: +' .. M.format_number(M.data.lines_added) .. ' -' .. M.format_number(M.data.lines_removed) .. ' ~' .. M.format_number(M.data.lines_edited) .. '\n\nToday:\n' },
    { ' Time: ' .. M.format_time(today_data.playtime) .. '\n' },
    { ' Lines: +' .. M.format_number(today_data.lines_added) .. ' -' .. M.format_number(today_data.lines_removed) .. ' ~' .. M.format_number(today_data.lines_edited) .. '\n' },
  }, true, {})
end

-- Show report
function M.show_report(arg)
  if arg == 'report' then
    local lines = M.build_report_lines()
    M.open_report_window(lines)
  else
    M.show_summary_echo()
  end
end

return M
