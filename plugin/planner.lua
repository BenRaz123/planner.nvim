if vim.g.loaded_planner == 1 then
	return
end

vim.g.loaded_planner = 1

local uv = vim.uv


local GCAL_REPO = "https://github.com/benraz123/gcal-py"
local DATADIR = vim.fn.stdpath("data") .. "/planner"
local DATAFILE = DATADIR .. "/db.json"
local REPO_PATH = DATADIR .. "/.gcal-repo"
-- Must point to an oauth2 credentials file (json) from google cloud console
local CREDENTIALS_FILE = DATADIR .. "/google_calendar_credentials.json"
local TOKEN_FILE = DATADIR .. "/google_calendar_token.json"
local DATE_FORMAT = "%Y-%m-%d"
local GCAL_BIN_PATH = DATADIR .. "/gcal"

-- takes in DATE_FORMAT and returns date_t
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

--- @param date osdate
--- @param delta integer
--- @return osdate
local function add_delta(date, delta)
	local ret = os.date("*t", os.time(date) + delta)
	--- @cast ret osdate
	return ret
end

local function file_exists(filepath)
	local f = io.open(filepath, "r")
	if f then
		io.close(f)
		return true
	else
		return false
	end
end

--- @param f string file to open. needs to be json
--- @return State
local function parse_from_file(f)
	local default = { list = {}, cursor = 1 }
	if not file_exists(f) then return default end
	local rawText = table.concat(vim.fn.readfile(f), "\n")
	if rawText == nil or rawText == "" then return default end
	local ok, decoded = pcall(vim.json.decode, rawText)
	if not ok or type(decoded) ~= "table" then
		return default
	end
	return { list = decoded, cursor = 1 }
end

--- @class Entry
--- @field category string the category this entry fits into
--- @field raw string the unparsed data of this entry
--- @field due integer epoch time of the due date
--- @field summary string summary of event
--- @field description string? an optional description of the event
--- @field duration integer? duration of the event in seconds
local Entry = {}
Entry.__index = Entry

--- @return Entry
function Entry.new()
	local ret = {}
	setmetatable(ret, Entry)
	return ret
end

--- @class State
--- @field list table<string, Entry[]>
--- @field cursor integer
local State = {}
State.__index = State

--- @param f string file to use as db
--- @return State
function State.new(f)
	local ret = parse_from_file(f)
	setmetatable(ret, State)
	return ret
end

--- @return string[]
local function splitn(str, delimiter, max_matches)
	local result = {}
	local start = 1
	local num_matches = 0

	if max_matches and max_matches < 1 then
		return { str }
	end

	while true do
		if max_matches and num_matches >= max_matches - 1 then
			-- For the last requested match, return the rest of the string.
			table.insert(result, string.sub(str, start))
			break
		end

		local split_start, split_end = string.find(str, delimiter, start, true)
		if not split_start then
			table.insert(result, string.sub(str, start))
			break
		end

		table.insert(result, string.sub(str, start, split_start - 1))
		start = split_end + 1
		num_matches = num_matches + 1
	end

	return result
end

local TDELTA_VALS = {
	d = 24 * 60 * 60,
	w = 7 * 24 * 60 * 60,
	h = 60 * 60,
	m = 60,
	s = 1,
}

local function trim(s)
	return string.gsub(s, "^%s*(.-)%s*$", "%1")
end

--- @param date osdate
--- @param hour integer?
--- @param minute integer?
--- @param am_pm_signifier string?
local function hm_extend_dt(date, hour, minute, am_pm_signifier)
	if hour ~= nil or minute ~= nil then
		--- @cast hour integer
		--- @cast minute integer
		--- @cast am_pm_signifier string
		date.hour = string.lower(am_pm_signifier) ~= 'a' and hour + 12 or hour
		date.min = minute
	end
end

--- @param date osdate date of the entry
--- @param str string to parse
--- @return Entry
function Entry.from_string(date, str)
	--- @type osdate
	local d = vim.deepcopy(date)
	local s = trim(string.gsub(str, "^- ", "", 1))

	local entry = Entry.new()

	local OFFSET_REGEX = "+(%d+)([dw])"
	local offset_number, offset_type = string.match(s, OFFSET_REGEX)
	s = trim(string.gsub(s, OFFSET_REGEX, "", 1))

	local HM_REGEX = "(%d+):(%d+)([apAP]?)[mM]?"
	local hour, minute, am_pm_distinguisher = string.match(s, HM_REGEX)
	s = trim(string.gsub(s, HM_REGEX, "", 1))

	local offset = (offset_number or 1) * TDELTA_VALS[offset_type or "d"]
	d = add_delta(d, offset)
	hm_extend_dt(d, hour, minute, am_pm_distinguisher)

	entry.due = os.time(d)

	local CATEGORY_REGEX = ":(%w+):"
	entry.category = string.match(s, CATEGORY_REGEX)
	s = trim(string.gsub(s, CATEGORY_REGEX, "", 1))

	local DESCRIPTION_REGEX = ": ?([^:]*)$"
	local descr = string.match(s, DESCRIPTION_REGEX)
	if descr ~= nil then
		entry.description = descr
		s = trim(string.gsub(s, DESCRIPTION_REGEX, "", 1))
	end

	local DURATION_REGEX_1 = "(%d+)h(%d+)m"
	local duration_hours, duration_minutes = string.match(s, DURATION_REGEX_1)

	if duration_hours ~= nil and duration_minutes ~= nil then
		s = trim(string.gsub(s, DURATION_REGEX_1, "", 1))
		entry.duration = tonumber(duration_minutes) * TDELTA_VALS.m + tonumber(duration_hours) * TDELTA_VALS.h
	else
		local DURATION_REGEX_2 = "(%d+)([hm])"
		local duration_multiplier, duration_type = string.match(s, DURATION_REGEX_2)
		if duration_multiplier ~= nil and duration_type ~= nil then
			entry.duration = tonumber(duration_multiplier) * TDELTA_VALS[duration_type]
			s = trim(string.gsub(s, DURATION_REGEX_2, "", 1))
		end
	end

	entry.raw = str
	entry.summary = s

	return entry
end

--- @param ev Entry
local function add_to_cal(ev)
	local title_case = function(str)
		local res = {}
		for _, word in ipairs(splitn(str, " ")) do
			if #word < 1 then goto continue end
			table.insert(res, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
			::continue::
		end
		return table.concat(res, " ")
	end
	local command = {
		GCAL_BIN_PATH,
		"--credentials-file", CREDENTIALS_FILE,
		"--token-file", TOKEN_FILE,
		"--summary", (ev.category and (title_case(ev.category) .. ": ") or "") .. title_case(ev.summary),
		"--description", ((ev.description ~= nil) and (ev.description .. " ") or "") ..
	"[Automatically generated by vim pln]",
		"--start-time", ev.due,
		"--time-zone", os.getenv("TZ") or "Etc/UTC"
	}

	if ev.duration ~= nil then
		table.insert(command, "--end-time")
		table.insert(command, ev.due + ev.duration)
	end

	vim.system(command, function(status)
		if status.code ~= 0 then
			vim.schedule(function()
				vim.notify(
					string.format("failed to upload calendar event (command %s failed with code %d): %s", GCAL_BIN_PATH,
						status.code, status.stderr), vim.log.levels.ERROR)
			end)
		end
	end)
end

-- parses in the format
-- - +1d 9:30pm science do homework
--- @param date osdate
--- @param str string[]
function State:add_markup(date, str)
	local new_entries = {}
	local formatted_date = os.date(DATE_FORMAT, os.time(date))
	local old_list = vim.deepcopy(self.list)
	self.list[formatted_date] = {}
	for _, line in ipairs(str) do
		if line == "" then goto continue end
		local entry = Entry.from_string(date, line)
		local unique = true
		if old_list == nil or old_list[formatted_date] == nil then goto skip_unique end
		for _, v in ipairs(old_list[formatted_date]) do
			if v.raw == entry.raw then
				unique = false
				break
			end
		end
		::skip_unique::
		if unique then table.insert(new_entries, entry) end
		table.insert(self.list[formatted_date], entry)
		::continue::
	end
	for _, ent in ipairs(new_entries) do
		add_to_cal(ent)
	end
end

--- @return integer
function State:len()
	local len = 0
	for _, _ in pairs(self.list) do
		len = len + 1
	end
	return len
end

--- @param i integer
function State:index(i)
	local index = 1
	for k, _ in pairs(self.list) do
		if i == index then return k end
		index = index + 1
	end
end

function State:next()
	if self.cursor == self:len() then
		self.cursor = 1
		return
	end
	self.cursor = self.cursor + 1
end

function State:prev()
	if self.cursor == 1 then
		self.cursor = self:len()
		return
	end
	self.cursor = self.cursor - 1
end

--- @return string[]
function State:display()
	local ret = { "Press `c` to create a new entry. Press `q` to quit", "" }
	if not self.list or self:len() == 0 then return ret end
	local idx = 1
	for date, _ in pairs(self.list) do
		if idx == self.cursor then
			table.insert(ret, "> " .. date)
		else
			table.insert(ret, "- " .. date)
		end
		idx = idx + 1
	end
	return ret
end

--- @param f string
function State:store(f)
	vim.fn.writefile(splitn(vim.json.encode(self.list), "\n"), f)
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

local function run()
	if not file_exists(CREDENTIALS_FILE) then
		vim.notify("no credential file found. to create one, see :PlnAddCredentials", vim.log.levels.ERROR)
		return
	end

	if vim.fn.isdirectory(DATADIR) == 0 then
		vim.fn.mkdir(DATADIR, "p")
	end

	local st = State.new(DATAFILE)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, { split = "left" })

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
			for _, ent in ipairs(st.list[date]) do table.insert(lines, ent.raw) end
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
				st:add_markup(parse_date_format(date), lines)
				st:store(DATAFILE)
				vim.bo[ev.buf].modified = false
				vim.api.nvim_win_close(win, true)
				run()
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
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, st:display())
		setb(buf, { modifiable = false })
	end

	buf_keymap_set(buf, "n", { "c" }, function()
		local date = os.date(DATE_FORMAT)
		runBuf(date)
	end)

	buf_keymap_set(buf, "n", { "j", "l", "<Right>", "<Down>" }, function()
		st:next()
		update()
	end)

	buf_keymap_set(buf, "n", { "k", "h", "<Left>", "<Up>", "<BS>" }, function()
		st:prev()
		update()
	end)

	buf_keymap_set(buf, "n", { "<Enter>" }, function()
		runBuf(st:index(st.cursor))
	end)

	buf_keymap_set(buf, "n", { "q" }, function()
		vim.api.nvim_win_close(win, true)
	end)
	update()
end

vim.api.nvim_create_user_command("Pln", run, { nargs = 0 })

local function install_gcal()
	vim.notify("starting process in background", vim.log.levels.INFO)
	vim.fn.delete(REPO_PATH, "rf")

	local cleanup = function()
		vim.schedule(function()
			vim.fn.delete(REPO_PATH, "rf")
		end)
	end

	local log_error = function(fmt, ...)
		local var_arg = { ... }
		vim.schedule(function()
			vim.notify("PlnInstallGcal: " .. string.format(fmt, unpack(var_arg)), vim.log.levels.ERROR)
		end)
		cleanup()
	end

	vim.system({ 'git', 'clone', GCAL_REPO, REPO_PATH }, { cwd = DATADIR }, function(ret)
		if ret.code ~= 0 then
			log_error("couldn't clone repo %s: %s", GCAL_REPO, ret.stderr)
			return
		end

		vim.system({ 'make', 'setup' }, { cwd = REPO_PATH }, function(make_setup_return)
			if make_setup_return.code ~= 0 then
				log_error("couldn't setup python environment (make setup returned code %d): %s", make_setup_return.code,
					make_setup_return.stderr)
				return
			end

			vim.system({ 'make', 'build' }, { cwd = REPO_PATH }, function(make_build_return)
				if make_build_return.code ~= 0 then
					log_error("couldn't build gcal executable (make build returned code %d): %s", make_build_return.code,
						make_build_return.stderr)
					return
				end

				local ok, err = uv.fs_copyfile(REPO_PATH .. '/dist/gcal', GCAL_BIN_PATH)

				if not ok then
					log_error("couldn't copy binary file %s/dist/gcal to %s: ", REPO_PATH, GCAL_BIN_PATH, err)
				end
				vim.schedule(function()
					vim.notify(":PlnInstallGcal: Finished installing gcal executable (" .. GCAL_BIN_PATH .. ")",
						vim.log.levels.INFO)
				end)
				cleanup()
			end)
		end)
	end)
end

vim.api.nvim_create_user_command("PlnInstallGcal", install_gcal, {})

local function add_credentials(file_name)
	local ok, err = uv.fs_copyfile(file_name, CREDENTIALS_FILE)

	if not ok then
		vim.notify(string.format("error copying file from %s to %s: %s", file_name, CREDENTIALS_FILE, err),
			vim.log.levels.ERROR)
		return
	end
end

vim.api.nvim_create_user_command("PlnAddCredentials", function(args)
	if args.nargs ~= "1" then
		vim.notify("need only one argument", vim.log.levels.ERROR)
		return
	end
	add_credentials(args.fargs[1])
end, { nargs = 1, complete = "file" })

vim.api.nvim_create_user_command("PlnReset", function()
	local handle = uv.fs_scandir(DATADIR)
	if not handle then
		vim.notify("couldn't get handle on directory " .. DATADIR, vim.log.levels.WARN)
		return
	end
	while true do
		local name, _ = uv.fs_scandir_next(handle)
		if not name then break end
		vim.fn.delete(DATADIR .. "/" .. name)
	end
end, {})

local M = {}
local initialized = false
M.setup = function(cred_file)
	vim.notify("initializing planner plugin", vim.log.levels.INFO)
	if initialized then return end
	initialized = true
	add_credentials(cred_file)
	install_gcal()
end
return M
