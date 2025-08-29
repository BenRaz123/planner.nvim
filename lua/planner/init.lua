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

local WARN = vim.log.levels.WARN
local ERROR = vim.log.levels.ERROR
local INFO = vim.log.levels.INFO

--- @param level vim.log.levels
--- @param fmt string
local function log(level, fmt, ...)
	local var_arg = { ... }
	vim.schedule(function()
		vim.notify(string.format(fmt, unpack(var_arg)), level)
	end)
end

--- @generic T
--- @param l T[]?
--- @param it T
local function append(l, it)
	if l ~= nil then
		table.insert(l, it)
	else
		log(WARN, "appending %s to empty list: %s", l, it)
		l = {it}
	end
end


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


--- @class Entry
--- @field gcal_id string? the google calendar id for this item. It was added to a google calendar if it ~= nil
--- @field category string the category this entry fits into
--- @field raw string the unparsed data of this entry
--- @field due integer epoch time of the due date
--- @field summary string summary of event
--- @field description string? an optional description of the event
--- @field duration integer? duration of the event in seconds

--- @param entries_table table<string, Entry[]>
--- @return string[]
local function keys(entries_table)
	local ret = {}
	for key in pairs(entries_table) do
		append(ret, key)
	end
	table.sort(ret, function(a, b) return a > b end)
	return ret
end

--- @class State
--- @field list table<string, Entry[]>
--- @field cursor integer

--- @param f string file to open. needs to be json
--- @return State
local function parse_from_file(f)
	local default = { list = {}, cursor = 1 }
	if not file_exists(f) then
		return default
	end
	local rawText = table.concat(vim.fn.readfile(f), "\n")
	if rawText == nil or rawText == "" then return default end
	local ok, decoded = pcall(vim.json.decode, rawText)
	if not ok or type(decoded) ~= "table" then
		return default
	end
	return { list = decoded, cursor = 1 }
end
--- @param st State
local function state_current_date(st)
	return keys(st.list)[st.cursor]
end

--- @param f string file to use as db
--- @return State
local function state_new(f)
	local ret = parse_from_file(f)
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
			append(result, string.sub(str, start))
			break
		end

		local split_start, split_end = string.find(str, delimiter, start, true)
		if not split_start then
			append(result, string.sub(str, start))
			break
		end

		append(result, string.sub(str, start, split_start - 1))
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
local function entry_from_string(date, str)
	--- @type osdate
	local d = vim.deepcopy(date)
	local s = vim.trim(string.gsub(str, "^- ", "", 1))

	local entry = {}

	local OFFSET_REGEX = "+(%d+)([dw])"
	local offset_number, offset_type = string.match(s, OFFSET_REGEX)
	s = vim.trim(string.gsub(s, OFFSET_REGEX, "", 1))

	local HM_REGEX = "(%d+):(%d+)([apAP]?)[mM]?"
	local hour, minute, am_pm_distinguisher = string.match(s, HM_REGEX)
	s = vim.trim(string.gsub(s, HM_REGEX, "", 1))

	local offset = (offset_number or 1) * TDELTA_VALS[offset_type or "d"]
	d = add_delta(d, offset)
	hm_extend_dt(d, hour, minute, am_pm_distinguisher)

	entry.due = os.time(d)

	local CATEGORY_REGEX = ":(%w+):"
	entry.category = string.match(s, CATEGORY_REGEX)
	s = vim.trim(string.gsub(s, CATEGORY_REGEX, "", 1))

	local DESCRIPTION_REGEX = ": ?([^:]*)$"
	local descr = string.match(s, DESCRIPTION_REGEX)
	if descr ~= nil then
		entry.description = descr
		s = vim.trim(string.gsub(s, DESCRIPTION_REGEX, "", 1))
	end

	local DURATION_REGEX_1 = "(%d+)h(%d+)m"
	local duration_hours, duration_minutes = string.match(s, DURATION_REGEX_1)

	if duration_hours ~= nil and duration_minutes ~= nil then
		s = vim.trim(string.gsub(s, DURATION_REGEX_1, "", 1))
		entry.duration = tonumber(duration_minutes) * TDELTA_VALS.m + tonumber(duration_hours) * TDELTA_VALS.h
	else
		local DURATION_REGEX_2 = "(%d+)([hm])"
		local duration_multiplier, duration_type = string.match(s, DURATION_REGEX_2)
		if duration_multiplier ~= nil and duration_type ~= nil then
			entry.duration = tonumber(duration_multiplier) * TDELTA_VALS[duration_type]
			s = vim.trim(string.gsub(s, DURATION_REGEX_2, "", 1))
		end
	end

	entry.raw = str
	entry.summary = s

	return entry
end

--- @param ent Entry
local function add_to_cal(ent)
	local title_case = function(str)
		local res = {}
		for _, word in ipairs(splitn(str, " ")) do
			if #word < 1 then goto continue end
			append(res, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
			::continue::
		end
		return table.concat(res, " ")
	end
	local command = {
		GCAL_BIN_PATH,
		"--credentials-file", CREDENTIALS_FILE,
		"--token-file", TOKEN_FILE,
		"create",
		"--summary", (ent.category and (title_case(ent.category) .. ": ") or "") .. title_case(ent.summary),
		"--description", ((ent.description ~= nil) and (ent.description .. " ") or "") ..
	"[Automatically generated by vim pln]",
		"--start-time", ent.due,
		"--time-zone", os.getenv("TZ") or "Etc/UTC"
	}

	if ent.duration ~= nil then
		append(command, "--end-time")
		append(command, ent.due + ent.duration)
	end

	local status = vim.system(command):wait()
	if status.code ~= 0 then
		vim.notify(
			string.format("failed to upload calendar event (command %s failed with code %d): %s", GCAL_BIN_PATH,
				status.code, status.stderr), vim.log.levels.ERROR)
	else
		ent.gcal_id = vim.trim(status.stdout)
	end
end

--- @param ent Entry
local function remove_from_cal(ent)
	vim.print("NTRY: ", ent)
	if ent.gcal_id == nil then return end
	local command = {
		GCAL_BIN_PATH,
		"--credentials-file", CREDENTIALS_FILE,
		"--token-file", TOKEN_FILE,
		"delete", ent.gcal_id
	}

	vim.system(command, function(status)
		if status.code ~= 0 then
			vim.schedule(function()
				vim.notify(
					string.format("failed to delete calendar event (command %s failed with code %d): %s", GCAL_BIN_PATH,
						status.code, status.stderr), vim.log.levels.ERROR)
			end)
		end
	end)
end

--- @param list Entry[]
--- @param item Entry
--- @return Entry?
--- returns true if the list has the item (one of the list's items matches the other ite's raw field)
local function contains(list, item)
	for _, entry in ipairs(list) do
		if entry.raw == item.raw then
			return entry
		end
	end
	return nil
end

--- @generic T
--- @generic U
--- @param list T[]
--- @param f fun(x: T): U?
--- @return U[]
local function collect(list, f)
	local ret = {}
	for _, item in ipairs(list) do
		local ret_val = f(item)
		if ret_val ~= nil then append(ret, ret_val) end
	end
	return ret
end

--- @generic T
--- @param list T[]
--- @param f fun(x: T)
local function for_each(list, f)
	if list == nil then return end
	for _, item in ipairs(list) do
		f(item)
	end
end

--- @param old Entry[]
--- @param buf Entry[]
--- @return Entry[]
local function intersection(old, buf)
	--- @type Entry[]
	local ret = {}
	for _, buf_ent in ipairs(buf) do
		local has, ent = contains(old, buf_ent)
		if has then
			append(ret, ent)
		end
	end
	return ret
end

--- @param old Entry[]
--- @param buf Entry[]
--- @return Entry[]
local function to_delete(old, buf)
	--- @type Entry[]
	local ret = {}
	for _, old_ent in ipairs(old) do
		local has, _ = contains(buf, old_ent)
		if not has then
			append(ret, old_ent)
		end
	end
	return ret
end

--- @param old Entry[]
--- @param buf Entry[]
--- @return Entry[]
local function new_entries(old, buf)
	--- @type Entry[]
	local ret = {}
	for _, buf_ent in ipairs(buf) do
		local has, _ = contains(old, buf_ent)
		if not has then
			append(ret, has)
		end
	end
	return ret
end

--- @param st State
--- @param date osdate
--- @param lines string[]
local function add_markup(st, date, lines)
	local formatted_date = os.date(DATE_FORMAT, os.time(date))
	--- @cast formatted_date string

	st.list[formatted_date] = st.list[formatted_date] or {}
	local old = vim.deepcopy(st.list[formatted_date]) or {}
	st.list[formatted_date] = {}
	for_each(old, function(ent)
		if ent.gcal_id == nil then
			log(WARN, "entry without gcal id: %s", ent.summary)
		end
	end)

	local buf = collect(lines, function(line)
		if vim.trim(line) ~= "" then
			return entry_from_string(date, line)
		end
	end)

	local delete = to_delete(old, buf)
	for_each(delete, function(ent) remove_from_cal(ent) end)

	for _, buf_item in ipairs(buf) do
		local old_item = contains(old, buf_item)
		if old_item ~= nil then
			log(INFO, "item has old equiv: %s", old_item)
			append(st.list[formatted_date], old_item)
		else
			log(INFO, "new item: %s", buf_item.summary)
			add_to_cal(buf_item)
			append(st.list[formatted_date], buf_item)
		end
	end
end

--- @return integer
--- @param st State
local function state_len(st)
	local len = 0
	for _, _ in pairs(st.list) do
		len = len + 1
	end
	return len
end

--- @param st State
--- @param i integer
--- @return Entry[]
local function state_index(st, i)
	return st.list[keys(st.list)[i]]
end

--- @param st State
local function state_next(st)
	if st.cursor == state_len(st) then
		st.cursor = 1
		return
	end
	st.cursor = st.cursor + 1
end

--- @param st State
local function state_prev(st)
	if st.cursor == 1 then
		st.cursor = state_len(st)
		return
	end
	st.cursor = st.cursor - 1
end

--- @param st State
--- @return string[]
local function state_display(st)
	local ret = { "Press `c` to create a new entry. Press `q` to quit", "" }
	if not st.list or state_len(st) == 0 then return ret end
	for idx, key in ipairs(keys(st.list)) do
		if idx == st.cursor then
			append(ret, "> " .. key)
		else
			append(ret, "- " .. key)
		end
	end
	return ret
end

--- @param st State
--- @param f string
local function state_store(st, f)
	vim.fn.writefile(splitn(vim.json.encode(st.list), "\n"), f)
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
	local ok, err = uv.fs_copyfile(file_name, CREDENTIALS_FILE)

	if not ok then
		vim.notify(string.format("error copying file from %s to %s: %s", file_name, CREDENTIALS_FILE, err),
			vim.log.levels.ERROR)
		return
	end
end

local M = {}
M.run = function()
	if not file_exists(CREDENTIALS_FILE) then
		vim.notify("no credential file found. to create one, see :PlnAddCredentials", vim.log.levels.ERROR)
		return
	end

	if vim.fn.isdirectory(DATADIR) == 0 then
		vim.fn.mkdir(DATADIR, "p")
	end

	local st = state_new(DATAFILE)
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
			for _, ent in ipairs(st.list[date]) do append(lines, ent.raw) end
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
				add_markup(st, parse_date_format(date), lines)
				vim.print(st)
				state_store(st, DATAFILE)
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
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, state_display(st))
		setb(buf, { modifiable = false })
	end

	buf_keymap_set(buf, "n", { "c" }, function()
		local date = os.date(DATE_FORMAT)
		--- @cast date string
		runBuf(date)
	end)

	buf_keymap_set(buf, "n", { "j", "l", "<Right>", "<Down>" }, function()
		state_next(st)
		update()
	end)

	buf_keymap_set(buf, "n", { "k", "h", "<Left>", "<Up>", "<BS>" }, function()
		state_prev(st)
		update()
	end)

	buf_keymap_set(buf, "n", { "<Enter>" }, function()
		runBuf(state_current_date(st))
	end)

	buf_keymap_set(buf, "n", { "q" }, function()
		vim.api.nvim_win_close(win, true)
	end)
	update()
end
M.install_gcal = function()
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

M.add_credentials = function(args)
	if args.nargs ~= "1" then
		vim.notify("need only one argument", vim.log.levels.ERROR)
		return
	end
	add_credentials(args.fargs[1])
end
M.reset = function()
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
end
M.setup = function(cred_file)
	if not file_exists(CREDENTIALS_FILE) then
		add_credentials(cred_file)
	end
	if not file_exists(GCAL_BIN_PATH) then
		M.install_gcal()
	end
end
return M
