local util = require "planner.util"
local conf = require "planner.config"
local state = require "planner.state"

local uv = vim.uv

local M = {}

--- @type StateCallback?
local Callback = nil

--- Parses DATE_FORMAT
--- @param ts string
--- @return osdate
local function parse_date_format(ts)
	local year, month, day = string.match(ts, "(%d+)-(%d+)-(%d+)")
	local current_date = os.date("*t")
	--- @cast current_date osdate
	current_date.year = year
	current_date.month = month
	current_date.day = day

	return current_date
end

local function setb(buf, opt)
	for key, val in pairs(opt) do
		vim.api.nvim_set_option_value(key, val, { buf = buf })
	end
end


local function setw(win, opt)
	for key, val in pairs(opt) do
		vim.api.nvim_set_option_value(key, val, { win = win })
	end
end

local function nshl(nsID, hl)
	for k, v in pairs(hl) do
		vim.api.nvim_set_hl(nsID, k, v)
	end
end

local function buf_keymap_set(buf, mode, rhss, fn)
	for _, rhs in ipairs(rhss) do
		vim.keymap.set(mode, rhs, fn, { buffer = buf })
	end
end

local function add_credentials(file_name)
	local ok, err = uv.fs_copyfile(file_name, conf.CREDENTIALS_FILE)

	if not ok then
		vim.notify(string.format("error copying file from %s to %s: %s", file_name, conf.CREDENTIALS_FILE, err),
			vim.log.levels.ERROR)
		return
	end
end

M.run = function()
	if not util.file_exists(conf.CREDENTIALS_FILE) then
		vim.notify("no credential file found. to create one, see :PlnAddCredentials", vim.log.levels.ERROR)
		return
	end

	if vim.fn.isdirectory(conf.DATADIR) == 0 then
		vim.fn.mkdir(conf.DATADIR, "p")
	end

	local st = state.new(conf.DATAFILE, Callback)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, { split = "left" })

	--- @param date string
	local function runBuf(date)
		vim.cmd [[enew]]

		local ed_buf = vim.api.nvim_get_current_buf()

		local pb_ns = vim.api.nvim_create_namespace("planner-buffer-ns")

		vim.api.nvim_buf_call(ed_buf, function()
			vim.cmd [[
				syntax match PlannerBufBullet /^-/
				syntax match PlannerBufOffset /+\d*[dw]/
				syntax match PlannerBufEventTime /\d\{1,2}:\d\{1,2}[APap]\?[Mm]\?/
				syntax match PlannerBufDuration /\d\+h\d\+m/
				syntax match PlannerBufDuration /\d\+[hm]/
				syntax match PlannerBufTag /:[^ ]\+:/
				syntax match PlannerBufDescription /: \?[^:]*$/
				]]
		end)
		nshl(pb_ns, {
			PlannerBufBullet = { link = "markdownListMarker" },
			PlannerBufOffset = { link = "Identifier" },
			PlannerBufEventTime = { link = "Identifier" },
			PlannerBufDuration = { link = "Identifier" },
			PlannerBufTag = { link = "Tag" },
			PlannerBufDescription = { link = "Comment" }
		})
		vim.api.nvim_win_set_hl_ns(win, pb_ns)


		if st.list[date] ~= nil then
			print("Editing " .. date)
			local lines = {}
			for _, ent in ipairs(st.list[date]) do
				util.append(lines, ent.raw)
			end
			vim.api.nvim_buf_set_lines(ed_buf, 0, -1, false, lines)
		else
			print("Editing " .. date .. " [new]")
		end
		vim.api.nvim_buf_set_name(ed_buf, "Planner" .. os.time())

		setb(ed_buf, {
			buftype = "acwrite",
			swapfile = false,
			bufhidden = "wipe"
		})

		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = ed_buf,
			callback = function(ev)
				local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
				state.add_markup(st, parse_date_format(date), lines)
				state.store(st, conf.DATAFILE)
				vim.bo[ev.buf].modified = false
				vim.api.nvim_win_close(win, true)
				M.run()
			end
		})
	end

	setw(win, {
		number = false,
		relativenumber = false
	})

	local pm_ns = vim.api.nvim_create_namespace('planner-menu-ns')
	vim.api.nvim_buf_call(buf, function()
		vim.cmd [[ syntax match PlannerMenuSelected /^>.*/
			syntax match PlannerMenuTitle /^\w.*/  ]]
	end)
	nshl(pm_ns, {
		PlannerMenuSelected = { bold = true, underline = true },
		PlannerMenuTitle = { italic = true }
	})
	vim.api.nvim_win_set_hl_ns(win, pm_ns)

	local update = function()
		setb(buf, { modifiable = true })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, state.display(st))
		setb(buf, { modifiable = false })
	end

	buf_keymap_set(buf, "n", { "c" }, function()
		local date = os.date(conf.DATE_FORMAT)
		--- @cast date string
		runBuf(date)
	end)

	buf_keymap_set(buf, "n", { "j", "l", "<Right>", "<Down>" }, function()
		state.next(st)
		update()
	end)

	buf_keymap_set(buf, "n", { "k", "h", "<Left>", "<Up>", "<BS>" }, function()
		state.prev(st)
		update()
	end)

	buf_keymap_set(buf, "n", { "<Enter>" }, function()
		runBuf(state.current_date(st))
	end)

	buf_keymap_set(buf, "n", { "q" }, function()
		vim.api.nvim_win_close(win, true)
	end)
	update()
end
M.install_gcal = function()
	vim.notify("starting process in background", vim.log.levels.INFO)
	vim.fn.delete(conf.REPO_PATH, "rf")

	local cleanup = function()
		vim.schedule(function()
			vim.fn.delete(conf.REPO_PATH, "rf")
		end)
	end

	local log_error = function(fmt, ...)
		local var_arg = { ... }
		vim.schedule(function()
			---@diagnostic disable-next-line: deprecated
			vim.notify("PlnInstallGcal: " .. string.format(fmt, unpack(var_arg)), vim.log.levels.ERROR)
		end)
		cleanup()
	end

	vim.system({ 'git', 'clone', conf.GCAL_REPO, conf.REPO_PATH }, { cwd = conf.DATADIR }, function(ret)
		if ret.code ~= 0 then
			log_error("couldn't clone repo %s: %s", conf.GCAL_REPO, ret.stderr)
			return
		end

		vim.system({ 'make', 'setup' }, { cwd = conf.REPO_PATH }, function(make_setup_return)
			if make_setup_return.code ~= 0 then
				log_error("couldn't setup python environment (make setup returned code %d): %s", make_setup_return.code,
					make_setup_return.stderr)
				return
			end

			vim.system({ 'make', 'build' }, { cwd = conf.REPO_PATH }, function(make_build_return)
				if make_build_return.code ~= 0 then
					log_error("couldn't build gcal executable (make build returned code %d): %s", make_build_return.code,
						make_build_return.stderr)
					return
				end

				local ok, err = uv.fs_copyfile(conf.REPO_PATH .. '/dist/gcal', conf.GCAL_BIN_PATH)

				if not ok then
					log_error("couldn't copy binary file %s/dist/gcal to %s: ", conf.REPO_PATH, conf.GCAL_BIN_PATH, err)
				end
				vim.schedule(function()
					vim.notify(":PlnInstallGcal: Finished installing gcal executable (" .. conf.GCAL_BIN_PATH .. ")",
						vim.log.levels.INFO)
				end)
				cleanup()
			end)
		end)
	end)
end

M.add_credentials = function(args)
	if args.nargs ~= "1" then
		vim.notify("need only one argument", vim.log.levels.ERROR)
		return
	end
	add_credentials(args.fargs[1])
end

M.reset = function()
	local handle = uv.fs_scandir(conf.DATADIR)
	if not handle then
		vim.notify("couldn't get handle on directory " .. conf.DATADIR, vim.log.levels.WARN)
		return
	end
	while true do
		local name, _ = uv.fs_scandir_next(handle)
		if not name then break end
		vim.fn.delete(conf.DATADIR .. "/" .. name)
	end
end

--- @param cred_file string
--- @param callback StateCallback?
M.setup = function(cred_file, callback)
	if not util.file_exists(conf.CREDENTIALS_FILE) then
		add_credentials(cred_file)
	end
	if not util.file_exists(conf.GCAL_BIN_PATH) then
		M.install_gcal()
	end
	Callback = callback
end
return M
