local M = {}

--- @generic T
--- @param l T[]?
--- @param it T
M.append = function(l, it)
	if l ~= nil then
		table.insert(l, it)
	else
		M.log(vim.log.levels.WARN, "appending %s to empty list: %s", l, it)
		l = { it }
	end
end

--- @param level vim.log.levels
--- @param fmt string
M.log = function(level, fmt, ...)
	local var_arg = { ... }
	vim.schedule(function()
		vim.notify(string.format(fmt, unpack(var_arg)), level)
	end)
end

--- returns true if a file exists, using [io.open](lua://io.open)
--- @return boolean
M.file_exists = function(filepath)
	local f = io.open(filepath, "r")
	if f then
		io.close(f)
		return true
	else
		return false
	end
end

--- @generic T
--- @generic U
--- @param list T[]
--- @param f fun(x: T): U?
--- @return U[]
M.collect = function(list, f)
	local ret = {}
	for _, item in ipairs(list) do
		local ret_val = f(item)
		if ret_val ~= nil then M.append(ret, ret_val) end
	end
	return ret
end

--- @generic T
--- @param list T[]
--- @param f fun(x: T)
M.for_each = function(list, f)
	if list == nil then return end
	for _, item in ipairs(list) do
		f(item)
	end
end

--- @param date osdate
--- @param hour integer?
--- @param minute integer?
--- @param am_pm_signifier string?
M.hm_extend_dt = function(date, hour, minute, am_pm_signifier)
	if hour ~= nil or minute ~= nil then
		--- @cast hour integer
		--- @cast minute integer
		--- @cast am_pm_signifier string
		date.hour = string.lower(am_pm_signifier) ~= 'a' and hour + 12 or hour
		date.min = minute
	end
end


--- @param date osdate
--- @param delta integer
--- @return osdate
M.add_delta = function(date, delta)
	local ret = os.date("*t", os.time(date) + delta)
	--- @cast ret osdate
	return ret
end

return M
