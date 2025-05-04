---@class ProjectRunner.Config
---@field tmux_window   string  Target tmux window id (e.g. "1" = second window)
---@field default_pre string  Global pre‑command (optional)
---@field default_post string Global post‑command (optional)
local default_config = {
	tmux_window = "1", -- default: second window of active window
	default_pre = "",
	default_post = "",
}

---@type ProjectRunner.Config
local config = vim.deepcopy(default_config)

local NUM_SLOTS = 9
local RUN_FILE = ".run"

-------------------------------------------------------------------------------
-- Helpers                                                                    |
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
	local contents = f:read("*a")
	f:close()
	local ok, parsed = pcall(vim.json.decode, contents)
	return ok and parsed or nil
end

---Upgrade legacy v1 flat‑string format to v2 table format.
---@param tbl table
---@return table
local function upgrade_if_needed(tbl)
	if tbl.slots then
		return tbl
	end -- already v2
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
		local data = load_json_file() or empty_project_table()
		project_cache = upgrade_if_needed(data)
	end
	return project_cache
end

---Persist the given project table to disk.
---@param tbl table
local function save_project(tbl)
	local ok, encoded = pcall(vim.json.encode, tbl)
	if not ok then
		vim.notify("[prun] Failed to encode .run", vim.log.levels.ERROR)
		return
	end
	local f, err = io.open(runfile_path(), "w")
	if not f then
		vim.notify("[prun] Cannot write .run: " .. err, vim.log.levels.ERROR)
		return
	end
	f:write(encoded)
	f:close()
end

---Apply placeholder template substitutions.
---Supported keys: %f, %F, %cwd, %s, %w (see README).
---@param str string
---@return string
local function apply_template(str)
	if str == "" then
		return str
	end
	local cwd = vim.fn.getcwd()
	local file = vim.api.nvim_buf_get_name(0)
	local fname = vim.fn.fnamemodify(file, ":t")
	local session = ""
	if vim.env.TMUX then
		local h = io.popen("tmux display-message -p '#S' 2>/dev/null")
		if h then
			session = (h:read("*l") or "")
			h:close()
		end
	end
	local map = {
		["%%f"] = file,
		["%%F"] = fname,
		["%%cwd"] = cwd,
		["%%s"] = session,
		["%%w"] = config.tmux_window,
	}
	local res = str
	for k, v in pairs(map) do
		res = res:gsub(k, v)
	end
	return res
end

---Send one command line to the configured tmux window.
---@param line string @Command already templated.
---@return boolean success
local function send_to_tmux(line)
	if not vim.env.TMUX then
		vim.notify("[prun] TMUX not detected.", vim.log.levels.ERROR)
		return false
	end
	local quoted = vim.fn.shellescape(line, true)
	local cmd = string.format("tmux send-keys -t %s %s Enter", config.tmux_window, quoted)
	local ok = os.execute(cmd)
	return ok == true or ok == 0
end

-------------------------------------------------------------------------------
-- Public API                                                                 |
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
	vim.notify("[prun] Project defaults saved.")
end

-------------------------------------------------------------------------------
-- Slot helpers                                                               |
-------------------------------------------------------------------------------

---Validate that `slot` is 1‑9.
---@param n integer
local function assert_slot(n)
	assert(type(n) == "number" and 1 <= n and n <= NUM_SLOTS, "slot 1‑9")
end

---Return the slot table for a given index.
---@param slot integer
---@return table<string,string>
local function slot_ref(slot)
	return get_project().slots[tostring(slot)]
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
-- Execution                                                                  |
-------------------------------------------------------------------------------

---Run the given slot (1‑9), prompting to set it if empty.
---@param slot integer
function M.run(slot)
	assert_slot(slot)
	local s = slot_ref(slot)
	if s.cmd == "" then
		vim.ui.input({ prompt = string.format("Set command for slot %d", slot) }, function(input)
			if not input or input == "" then
				return
			end
			s.cmd = input
			persist()
			M.run(slot)
		end)
		return
	end
	local pre, post = resolve_pre_post(s)
	local sequence = { pre, s.cmd, post }
	for idx, line in ipairs(sequence) do
		if line ~= "" then
			local expanded = apply_template(line)
			if idx == 1 then
				vim.notify("[prun] running pre command")
			elseif idx == 2 then
				vim.notify("[prun]  " .. expanded)
			else
				vim.notify("[prun] running post command")
			end
			if not send_to_tmux(expanded) then
				break
			end
		end
	end
end

-------------------------------------------------------------------------------
-- Editing                                                                    |
-------------------------------------------------------------------------------

---Edit a slot’s cmd / pre / post values via `vim.ui.input`.
---@param slot integer
function M.edit(slot)
	assert_slot(slot)
	local s = slot_ref(slot)
	vim.ui.select({ "cmd", "pre", "post" }, { prompt = "Which field to edit?" }, function(field)
		if not field then
			return
		end
		vim.ui.input(
			{ prompt = string.format("Edit %s for slot %d", field, slot), default = s[field] or "" },
			function(val)
				if val ~= nil then
					s[field] = val
					persist()
					vim.notify("[prun] Updated.")
				end
			end
		)
	end)
end

---Delete a slot (clears cmd, pre, post).
---@param slot integer
function M.delete(slot)
	assert_slot(slot)
	local s = slot_ref(slot)
	s.cmd, s.pre, s.post = "", "", ""
	persist()
	vim.notify(string.format("[prun] Cleared slot %d", slot))
end

---Interactive UI to run/edit/delete slots.
function M.manage()
	local items, map = {}, {}
	for i = 1, NUM_SLOTS do
		local t = slot_ref(i)
		table.insert(items, string.format("%d: %s", i, t.cmd ~= "" and t.cmd or "<empty>"))
		map[#items] = i
	end
	vim.ui.select(items, { prompt = "Manage command slot" }, function(_, idx)
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
