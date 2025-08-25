if vim.g.loaded_planner == 1 then
	return
end

vim.g.loaded_planner = 1

local DATADIR = vim.fn.stdpath("data") .. "/planner"
local DATAFILE = DATADIR .. "/db.json"
-- Must point to an oauth2 credentials file (json) from google cloud console
local CREDENTIALS_FILE = DATADIR .. "/google_calendar_credentials.json"
local TOKEN_FILE = DATADIR .. "/google_calendar_token.json"
local DATE_FORMAT = "%Y-%m-%d"
local PROG_NAME = DATADIR .. "/gcal"

-- takes in DATE_FORMAT and returns date_t
local function parse_date_format(ts)
	local current_date = os.date("*t")
	local y = 0
	local m = 0
	local d = 0
	for year, month, day in string.gmatch(ts, "(%d+)-(%d+)-(%d+)") do
		y = tonumber(year)
		m = tonumber(month)
		d = tonumber(day)
	end
	current_date.year = y
	current_date.month = m
	current_date.day = d

	return current_date
end

--local function make_new(ty, default)
--	local def = (type(default) == "function") and default() or default
--	return function(ty)
--		local o = def
--		setmetatable(o, ty)
--		ty.__index = ty
--		return o
--	end
--end

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
--[[EXAMPLE

example
	["3/14/2008"] = {
		{cat= "a", date="b", due="aa"},
		{cat= "a", date="b", due="aa"},
		{cat= "a", date="b", due="aa"}
	},
	["10/7/2008"] = {
		{cat= "a", date="b", due="aa"},
		{cat= "a", date="b", due="aa"},
		{cat= "a", date="b", due="aa"}
	}

]] --

--- @class Entry
--- @field category string the category this entry fits into
--- @field raw string the unparsed data of this entry
--- @field due integer epoch time of the due date
--- @field summary string summary of event
--@field description string? an optional description of the event
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
	vim.print(str)
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

local function parse_time_delta(tdelta)
	local t = ""
	local d = ""
	for delta, type in string.gmatch(tdelta, "+(%d+)(%a)") do
		d = delta
		t = type
	end
	return { delta = d, type = t }
end

local TDELTA_VALS = {
	d = 24 * 60 * 60,
	w = 7 * 24 * 60 * 60
}

local function trim(s)
  return string.gsub(s, "^%s*(.-)%s*$", "%1")
end

--- @param date osdate
--- @param hour integer?
--- @param minute integer?
--- @param am_pm_signifier string?
local function hm_extend_dt(date, hour, minute, am_pm_signifier)
	local ret = os.date("*t")
	if hour ~= nil or minute ~= nil then
		--- @cast hour integer
		--- @cast minute integer
		--- @cast am_pm_signifier string 
		ret.hour = string.lower(am_pm_signifier) ~= 'a' and hour+12 or hour
		ret.min = minute
	end
	date.hour = ret.hour
	date.min = ret.min
end

--- @param date osdate date of the entry
--- @param str string to parse
--- @return Entry
function Entry.from_string(date, str)
	--- @type osdate
	local d = vim.deepcopy(date)
	local s = trim(splitn(str, "- ", 2)[2])

	local entry = Entry.new()

	local OFFSET_REGEX = "+(%d+)([dw])"
	local offset_number, offset_type = string.match(s, OFFSET_REGEX)
	s = trim(string.gsub(s, OFFSET_REGEX, "", 1))

	local HM_REGEX = "(%d+):(%d+)([apAP]?)[mM]?"
	local hour, minute, am_pm_distinguisher = string.match(s, HM_REGEX)
	s = trim(string.gsub(s, HM_REGEX, "", 1))

	if offset_number ~= nil then
		local offset = offset_number * TDELTA_VALS[offset_type or "d"]
		local due = add_delta(date, offset)
		d = due
	end

	hm_extend_dt(d, hour, minute, am_pm_distinguisher)

	entry.due = os.time(date)

	local CATEGORY_REGEX = ":(%w+):"
	entry.category = string.match(s, CATEGORY_REGEX)
	entry.summary = trim(string.gsub(s, CATEGORY_REGEX, "", 1))
	entry.raw = str

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
	vim.system {
		PROG_NAME,
		"--summary", title_case(ev.category) .. ": " .. title_case(ev.summary),
		"--description", "automatically generated by vim pln",
		"--start-time", ev.due,
		"--time-zone", os.getenv("TZ") or "Etc/UTC"
	}
end

-- parses in the format
-- - +1d 9:30pm science do homework
--- @param date osdate 
--- @param str string[]
function State:add_markup(date, str)
	local new_entries = {}
	local formatted_date = os.date(DATE_FORMAT, os.time(date))
	self.list[formatted_date] = {}
	for _, line in ipairs(str) do
		if line == "" then goto continue end
		local entry = Entry.from_string(date, line)
		local unique = true
		for _, v in ipairs(self.list[formatted_date]) do
			if v.raw == entry.raw then
				unique = false
				break
			end
		end
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
	if vim.fn.isdirectory(DATADIR) == 0 then
		vim.fn.mkdir(DATADIR, "p")
	end

	local st = State:new()
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, { split = "left" })

	local runBuf = function(date)
		vim.cmd [[enew]]
		local ed_buf = vim.api.nvim_get_current_buf()
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

vim.api.nvim_create_user_command("Pln", run, { desc = "Run the planner" })

vim.api.nvim_create_user_command("PlnAddCredentials", function(args)
	if args.nargs ~= 1 then
		print("Error: Need only one argument")
		return
	end

	print(args.fargs[1])
end, { nargs = 1, complete = "file", desc = "Add a credentials.json file from Google Cloud Platform" })

vim.api.nvim_create_user_command("PlnReset", function()
	vim.fn.writefile({}, DATAFILE)
end, { desc = "Delete database file (can be found at " .. DATAFILE .. ")" })
