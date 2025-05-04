---@class ProjectRunner.Config
---@field tmux_window   string  Target tmux window id (e.g. "1" = second window)
---@field default_pre   string  Global pre‑command (optional)
---@field default_post  string  Global post‑command (optional)
local default_config = {
	tmux_window = "1",
	default_pre = "",
	default_post = "",
}

---@type ProjectRunner.Config
local config = vim.deepcopy(default_config)

local NUM_SLOTS = 9
local RUN_FILE = ".run"

-------------------------------------------------------------------------------
-- Helper: project persistence                                                |
-------------------------------------------------------------------------------

---Return absolute path of the project `.run` file.
---@return string
local function runfile_path()
	return vim.fn.getcwd() .. "/" .. RUN_FILE
end

---Create a fresh project table with empty slots.
---@return table<string, any>
local function empty_project_table()
	local t = {
		_project_default_pre = "",
		_project_default_post = "",
		slots = {},
	}
	for i = 1, NUM_SLOTS do
		t.slots[tostring(i)] = { cmd = "", pre = "", post = "" }
	end
	return t
end

---Read and decode JSON from the `.run` file.
---Returns `nil` on error (caller handles fallback).
---@return table|nil
local function load_json_file()
	local f = io.open(runfile_path(), "r")
	if not f then
		return nil
	end
	local ok, parsed = pcall(vim.json.decode, f:read("*a"))
	f:close()
	return ok and parsed or nil
end

---@param tbl table
---@return table
local function upgrade_if_needed(tbl)
	if tbl.slots then
		return tbl
	end
	local t = empty_project_table()
	for i = 1, NUM_SLOTS do
		local s = tbl[tostring(i)]
		if type(s) == "string" then
			t.slots[tostring(i)].cmd = s
		end
	end
	return t
end

---Cached project table accessor.
---@return table
local project_cache ---@type table|nil
local function get_project()
	if not project_cache then
		project_cache = upgrade_if_needed(load_json_file() or empty_project_table())
	end
	return project_cache
end

---@param tbl table
local function save_project(tbl)
	local ok, encoded = pcall(vim.json.encode, tbl)
	if not ok then
		return vim.notify("[prun] encode failed", vim.log.levels.ERROR)
	end
	local f, err = io.open(runfile_path(), "w")
	if not f then
		return vim.notify("[prun] write .run: " .. err, vim.log.levels.ERROR)
	end
	f:write(encoded)
	f:close()
end

-------------------------------------------------------------------------------
-- Helper: templating                                                        |
-------------------------------------------------------------------------------

local function apply_template(str)
	if str == "" then
		return str
	end
	local map = {
		["%%f"] = vim.api.nvim_buf_get_name(0),
		["%%F"] = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"),
		["%%cwd"] = vim.fn.getcwd(),
		["%%w"] = config.tmux_window,
		["%%s"] = (function()
			if not vim.env.TMUX then
				return ""
			end
			local h = io.popen("tmux display-message -p '#S' 2>/dev/null")
			if not h then
				return ""
			end
			local s = h:read("*l") or ""
			h:close()
			return s
		end)(),
	}
	local res = str
	for k, v in pairs(map) do
		res = res:gsub(k, v)
	end
	return res
end

-------------------------------------------------------------------------------
-- Helper: execution targets                                                 |
-------------------------------------------------------------------------------

---Send line to tmux window (quoted) – keeps previous behaviour.
---@param line string @Command already templated.
---@return boolean success
local function exec_tmux(line)
	if not vim.env.TMUX then
		vim.notify("[prun] TMUX not detected", vim.log.levels.ERROR)
		return false
	end
	local quoted = vim.fn.shellescape(line, true)
	local cmd = string.format("tmux send-keys -t %s %s Enter", config.tmux_window, quoted)
	local ok = os.execute(cmd)
	return ok == true or ok == 0
end

---Execute via os.execute in a detached subshell (stdout/stderr sent to Neovim).
---@param line string
local function exec_shell(line)
	local ok = os.execute(line .. " >/dev/null 2>&1 &")
	return ok == true or ok == 0
end

---Parse optional execution tag. Returns executor fn and cleaned command.
---@param raw string
---@return fun(string):boolean executor
---@return string cmd
local function parse_target(raw)
	local tag, body = raw:match("^%[(%w+)%]%s*(.*)$")
	if not tag then
		return exec_tmux, raw
	end
	tag = tag:lower()
	if tag == "sh" or tag == "shell" then
		return exec_shell, body
	elseif tag == "tmux" then
		return exec_tmux, body
	else
		-- unknown tag → default to tmux
		return exec_tmux, raw
	end
end

-------------------------------------------------------------------------------
-- Public API                                                                |
-------------------------------------------------------------------------------
local M = {}

---Apply user configuration.
---@param opts ProjectRunner.Config|nil
function M.setup(opts)
	if opts then
		config = vim.tbl_deep_extend("force", config, opts)
	end
end

---Return a deep copy of the current slot table.
---@return table<string, {cmd:string,pre:string,post:string}>
function M.list()
	return vim.deepcopy(get_project().slots)
end

---Set per‑project default pre/post commands.
---@param pre  string|nil
---@param post string|nil
function M.set_project_defaults(pre, post)
	local p = get_project()
	if pre then
		p._project_default_pre = pre
	end
	if post then
		p._project_default_post = post
	end
	save_project(p)
	vim.notify("[prun] Project defaults saved")
end

-------------------------------------------------------------------------------
-- Slot utilities                                                            |
-------------------------------------------------------------------------------
local function assert_slot(n)
	assert(type(n) == "number" and 1 <= n and n <= NUM_SLOTS, "slot 1-9")
end
---Return the slot table for a given index.
---@param i integer
---@return table<string,string>
local function slot_ref(i)
	return get_project().slots[tostring(i)]
end
---Persist current cache to disk.
local function persist()
	save_project(get_project())
end

---Resolve effective pre/post for a slot (cascade slot → project → global).
---@param slot_tbl table<string,string>
---@return string pre
---@return string post
local function resolve_pre_post(slot_tbl)
	local pj = get_project()
	local pre = slot_tbl.pre ~= "" and slot_tbl.pre
		or pj._project_default_pre ~= "" and pj._project_default_pre
		or config.default_pre
		or ""
	local post = slot_tbl.post ~= "" and slot_tbl.post
		or pj._project_default_post ~= "" and pj._project_default_post
		or config.default_post
		or ""
	return pre, post
end

-------------------------------------------------------------------------------
-- Runner                                                                    |
-------------------------------------------------------------------------------
function M.run(slot)
	assert_slot(slot)
	local s = slot_ref(slot)
	if s.cmd == "" then
		return vim.ui.input({ prompt = "Set command for slot " .. slot }, function(inp)
			if inp and inp ~= "" then
				s.cmd = inp
				persist()
				M.run(slot)
			end
		end)
	end
	local pre, post = resolve_pre_post(s)
	local sequence = { pre, s.cmd, post }
	for idx, raw in ipairs(sequence) do
		if raw ~= "" then
			local exec, body = parse_target(raw)
			body = apply_template(body)
			if idx == 1 then
				vim.notify("[prun] pre ➜ " .. body)
			elseif idx == 2 then
				vim.notify("[prun] cmd ➜ " .. body)
			else
				vim.notify("[prun] post ➜ " .. body)
			end
			if not exec(body) then
				break
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Editing / manage                                                          |
-------------------------------------------------------------------------------

---Edit a slot’s cmd / pre / post values via `vim.ui.input`.
---@param slot integer
function M.edit(slot)
	assert_slot(slot)
	local s = slot_ref(slot)
	vim.ui.select({ "cmd", "pre", "post" }, { prompt = "Field to edit" }, function(field)
		if not field then
			return
		end
		vim.ui.input({ prompt = string.format("Edit %s for %d", field, slot), default = s[field] }, function(val)
			if val ~= nil then
				s[field] = val
				persist()
				vim.notify("[prun] updated")
			end
		end)
	end)
end

function M.delete(slot)
	assert_slot(slot)
	slot_ref(slot).cmd, slot_ref(slot).pre, slot_ref(slot).post = "", "", ""
	persist()
	vim.notify("[prun] cleared " .. slot)
end

function M.manage()
	local items, map = {}, {}
	for i = 1, NUM_SLOTS do
		local t = slot_ref(i)
		table.insert(items, string.format("%d: %s", i, t.cmd ~= "" and t.cmd or "<empty>"))
		map[#items] = i
	end
	vim.ui.select(items, { prompt = "Manage slot" }, function(_, idx)
		if not idx then
			return
		end
		local slot = map[idx]
		vim.ui.select({ "Run", "Edit", "Delete" }, { prompt = "Action" }, function(choice)
			if choice == "Run" then
				M.run(slot)
			elseif choice == "Edit" then
				M.edit(slot)
			elseif choice == "Delete" then
				M.delete(slot)
			end
		end)
	end)
end

return M
