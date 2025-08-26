if vim.g.loaded_planner == 1 then
	return
end

vim.g.loaded_planner = 1

local pln = require("planner")

vim.api.nvim_create_user_command("Pln", pln.run, {})
vim.api.nvim_create_user_command("PlnReset", pln.reset, {})
vim.api.nvim_create_user_command("PlnAddCredentials", pln.add_credentials, { nargs = 1, complete = "file" })
vim.api.nvim_create_user_command("PlnInstallGcal", pln.install_gcal, {})
