local api = vim.api
vim.cmd [[
  source ~/.config/nvim/options.vim
  source ~/.config/nvim/mappings.vim
  source ~/.config/nvim/plugin_options.vim
]]

vim.g.python3_host_prog = vim.fn.expand('$HOME/.virtualenvs/nvim/bin/python')
vim.o.laststatus = 3
vim.o.scrollback=100000

local keymap = vim.keymap
local accept_compl_or_cr = function()
  return require('lsp_compl').accept_pum() and '<c-y>' or '<CR>'
end
keymap.set('i', '<CR>', accept_compl_or_cr, { expr = true })
keymap.set({'i', 's'}, '<ESC>', function()
  require('luasnip').unlink_current()
  return '<ESC>'
end, { expr = true })

keymap.set('n', 'gs', [[:let @/='\<'.expand('<cword>').'\>'<CR>cgn]])
keymap.set('x', 'gs', [["sy:let @/=@s<CR>cgn]])

keymap.set('n', ']q', ':cnext<CR>')
keymap.set('n', '[q', ':cprevious<CR>')
keymap.set('n', ']Q', ':cfirst<CR>')
keymap.set('n', '[Q', ':clast<CR>')
keymap.set('n', ']l', ':lnext<CR>')
keymap.set('n', '[l', ':lprevious<CR>')
keymap.set('n', ']L', ':lfirst<CR>')
keymap.set('n', '[L', ':llast<CR>')


local function diagnostic_severity()
  local num_warnings = 0
  for _, d in ipairs(vim.diagnostic.get(0)) do
    if d.severity == vim.diagnostic.severity.ERROR then
      return vim.diagnostic.severity.ERROR
    elseif d.severity == vim.diagnostic.severity.WARN then
      num_warnings = num_warnings + 1
    end
  end
  if num_warnings > 0 then
    return vim.diagnostic.severity.WARN
  else
    return nil
  end
end
keymap.set('n', ']w', function()
  vim.diagnostic.goto_next({ severity = diagnostic_severity() })
end)
keymap.set('n', '[w', function()
  vim.diagnostic.goto_prev({ severity = diagnostic_severity() })
end)


keymap.set('n', ']v', function() require('me.lsp').next_highlight() end)
keymap.set('n', '[v', function() require('me.lsp').prev_highlight() end)

keymap.set('n', '<leader>q', function() require('quickfix').toggle() end, { silent = true })
keymap.set('n', '<leader>lq', function() require('quickfix').load() end, { silent = true })

local me = require('me')
me.setup()
require('me.fzy').setup()
require('me.dap').setup()
require('me.lsp').setup()

vim.g.clipboard = {
  name = 'wl-link-paste',
  copy = {
    ['+'] = {'wl-copy', '--type', 'text/plain'},
    ['*'] = {'wl-copy', '--primary', '--type', 'text/plain'},
  },
  paste = {
    ['+'] = me.paste(),
    ['*'] = me.paste("--primary"),
  }
}

do
  local lint = require('lint')
  lint.linters_by_ft = {
    markdown = {'vale', 'markdownlint'},
    rst = {'vale'},
    java = {'codespell'},
    lua = {'codespell', 'luacheck'},
    sh = {'shellcheck'},
    ['yaml.ansible'] = {'ansible_lint'},
    yaml = {'yamllint'},
    gitcommit = {'codespell'},
    dockerfile = {'hadolint'},
  }
  api.nvim_create_autocmd({'BufWritePost', 'BufEnter', 'BufLeave'}, {
    group = api.nvim_create_augroup('lint', { clear = true }),
    callback = function() lint.try_lint() end,
  })
end

api.nvim_create_user_command('Grep', 'silent grep! <args> | copen | wincmd p', { nargs = '+' })


do
  local did_setup = false
  local function neotest()
    vim.cmd.packadd('neotest')
    vim.cmd.packadd('neotest-plenary')
    vim.cmd.packadd('nvim-treesitter')
    local n = require('neotest')
    if not did_setup then
      did_setup = true
      n.setup({
        adapters = {
          require('neotest-plenary'),
        },
      })
    end
    return n
  end
  keymap.set('n', 't<C-n>', function() neotest().run.run() end)
  keymap.set('n', 't<C-l>', function() neotest().run.run_last() end)
  keymap.set('n', 't<C-f>', function() neotest().run.run(vim.fn.expand('%')) end)
end
