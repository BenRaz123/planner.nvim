local M = {}
M.GCAL_REPO = "https://github.com/benraz123/gcal-py"
M.DATADIR = vim.fn.stdpath("data") .. "/planner"
M.DATAFILE = M.DATADIR .. "/db.json"
M.REPO_PATH = M.DATADIR .. "/.gcal-repo"
M.CREDENTIALS_FILE = M.DATADIR .. "/google_calendar_credentials.json"
M.TOKEN_FILE = M.DATADIR .. "/google_calendar_token.json"
M.DATE_FORMAT = "%Y-%m-%d"
M.GCAL_BIN_PATH = M.DATADIR .. "/gcal"

M.WARN = vim.log.levels.WARN
M.ERROR = vim.log.levels.ERROR
M.INFO = vim.log.levels.INFO
return M
