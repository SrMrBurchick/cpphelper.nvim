local api = vim.api
local commands = require('helper.commands')
local telescope = require('telescope')

vim.g.preforce_nvim_version = '0.0.1'

api.nvim_create_user_command('CPPHelper', function(args)
  commands.load_command(unpack(args.fargs))
end, {
  range = true,
  nargs = '+',
  complete = function(arg)
    local list = require('helper.commands').commands_list()
    return vim.tbl_filter(function(s)
      return string.match(s, '^' .. arg)
    end, list)
  end,
})


telescope.load_extension('cpphelper')
-- LSP Setup
-- vim.lsp.config['cpp_helper'] = require('helper.lsp.cpp_helper')
-- vim.lsp.enable('cpp_helper')
