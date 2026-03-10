local helper_telescope = require('helper.telescope')
local telescope = require('telescope')

return telescope.register_extension {
	exports = {
		find_solution = helper_telescope.find_solution,
		generate_compile_commands = helper_telescope.generate_compile_commands,
	}
}
