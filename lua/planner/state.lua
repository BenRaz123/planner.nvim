local util = require "planner.util"
local conf = require "planner.config"
local entry = require "planner.entry"

local M = {}

--- @param old Entry[]
--- @param buf Entry[]
--- @return Entry[]
local function to_delete(old, buf)
	--- @type Entry[]
	local ret = {}
	for _, old_ent in ipairs(old) do
		local has, _ = entry.contains(buf, old_ent)
		if not has then
			util.append(ret, old_ent)
		end
	end
	return ret
end

--- @class State
--- @field list table<string, Entry[]>
--- @field cursor integer

--- @param f string file to open. needs to be json
--- @return State
M.parse_from_file = function(f)
	local default = { list = {}, cursor = 1 }
	if not util.file_exists(f) then
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
--- @return string[]
M.keys = function(st)
	local ret = {}
	vim.print(st)
	if st.list ~= nil then
		for key in pairs(st.list) do
			util.append(ret, key)
		end
		table.sort(ret, function(a, b) return a > b end)
	end
	return ret
end

--- @param st State
M.current_date = function(st)
	return M.keys(st)[st.cursor]
end

--- @param f string file to use as db
--- @return State
M.new = function(f)
	local ret = M.parse_from_file(f)
	return ret
end

--- @param st State
--- @param date osdate
--- @param lines string[]
M.add_markup = function(st, date, lines)
	local formatted_date = os.date(conf.DATE_FORMAT, os.time(date))
	--- @cast formatted_date string

	st.list[formatted_date] = st.list[formatted_date] or {}
	local old = vim.deepcopy(st.list[formatted_date]) or {}
	st.list[formatted_date] = {}
	util.for_each(old, function(ent)
		if ent.gcal_id == nil then
			util.log(conf.WARN, "entry without gcal id: %s", ent.summary)
		end
	end)

	local buf = util.collect(lines, function(line)
		if vim.trim(line) ~= "" then
			return entry.from_string(date, line)
		end
	end)

	local delete = to_delete(old, buf)
	util.for_each(delete, function(ent) entry.remove_from_cal(ent) end)

	for _, buf_item in ipairs(buf) do
		local old_item = entry.contains(old, buf_item)
		if old_item ~= nil then
			util.log(conf.INFO, "item has old equiv: %s", old_item)
			util.append(st.list[formatted_date], old_item)
		else
			util.log(conf.INFO, "new item: %s", buf_item.summary)
			entry.add_to_cal(buf_item)
			util.append(st.list[formatted_date], buf_item)
		end
	end
end

--- @return integer
--- @param st State
M.len = function(st)
	local len = 0
	for _, _ in pairs(st.list) do
		len = len + 1
	end
	return len
end

--- @param st State
--- @param i integer
--- @return Entry[]
M.index = function(st, i)
	return st.list[M.keys(st)[i]]
end

--- @param st State
M.next = function(st)
	if st.cursor == M.len(st) then
		st.cursor = 1
		return
	end
	st.cursor = st.cursor + 1
end

--- @param st State
M.prev = function(st)
	if st.cursor == 1 then
		st.cursor = M.len(st)
		return
	end
	st.cursor = st.cursor - 1
end

--- @param st State
--- @return string[]
M.display = function(st)
	local ret = { "Press `c` to create a new entry. Press `q` to quit", "" }
	if not st.list or M.len(st) == 0 then 
		print("triggered")
		return ret
	end
	for idx, key in ipairs(M.keys(st)) do
		if idx == st.cursor then
			util.append(ret, "> " .. key)
		else
			util.append(ret, "- " .. key)
		end
	end
	return ret
end

--- @param st State
--- @param f string
M.store = function(st, f)
	vim.fn.writefile(vim.split(vim.json.encode(st.list), "\n"), f)
end

return M
