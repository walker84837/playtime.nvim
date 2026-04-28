local M = {}

local function check_version()
  local min_version = vim.version.parse('0.10.0')
  if vim.version().major < min_version.major or
    (vim.version().major == min_version.major and vim.version().minor < min_version.minor) then
    vim.notify(('playtime.nvim requires Neovim %s+, you have %s'):format(
      min_version,
      vim.version()
    ), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.setup()
  if not check_version() then return end
  local playtime = require('playtime.playtime')

  -- Initialize data
  playtime.load_data()

  -- Register activity autocmds
  vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI', 'InsertEnter', 'TextChanged', 'TextChangedI'}, {
    callback = function()
      playtime.update_activity()
    end
  })

  -- Attach to buffers for line tracking
  vim.api.nvim_create_autocmd({'BufRead', 'BufNewFile'}, {
    callback = function(args)
      playtime.attach_buffer(args.buf)
    end
  })

  -- Cleanup on buffer unload
  vim.api.nvim_create_autocmd({'BufDelete', 'BufWipeout'}, {
    callback = function(args)
      playtime.buffers[args.buf] = nil
    end
  })

  -- Register command
  vim.api.nvim_create_user_command('Playtime', function(opts)
    playtime.show_report(opts.args)
  end, {
    nargs = '?',
    complete = function()
      return { 'report' }
    end
  })

  -- Save data on exit
  vim.api.nvim_create_autocmd('VimLeavePre', {
    callback = function()
      playtime.save_data()
      playtime.stop_timer()
    end
  })
end

return M
