# prun.nvim - Project-local Command Runner

A minimal Neovim plugin that lets every project keep **up to nine shell commands** (plus optional _pre_ and _post_ hooks) in a local `.prun` file. Commands are dispatched to a configurable **tmux window** so output stays neatly in your terminal workflow.

---

## ✨ Features

- **Nine command slots / project** - editable, runnable, deletable.
- **Per-slot, per-project & global** _pre/post_ hooks.
- **`.prun` file** lives in the project root - commit it or add to `.gitignore`.
- **Templating**

  - `%f` full path of current file
  - `%F` filename only
  - `%cwd` current working directory
  - `%s` tmux session name
  - `%w` configured window id

- Pure Lua, no external deps (just `tmux`).
- No keymaps; clean API for you to bind.

---

## 🚀 Installation

```lua
-- lazy.nvim / folke/lazy.nvim
{
  "marco/prun.nvim",
  config = function()
    require("prun").setup({
      tmux_window   = "2",          -- third window (0-indexed in tmux)
      default_pre = "echo PRE",     -- optional global hooks
    })
  end,
}
```

---

## ⚙️ Configuration

```lua
require("prun").setup({
  tmux_window  = "1",             -- default window ("1" = second window)
  default_pre  = "echo start",    -- global pre-hook (optional)
  default_post = "echo done",     -- global post-hook (optional)
})
```

### Project defaults

Inside any project directory:

```lua
local prun = require("prun")
prun.set_project_defaults("echo project-pre", "echo project-post")
```

These are stored in the same `.prun` file.

---

## 🖱️ Keymap ideas

```lua
local prun = require("prun")

vim.keymap.set("n", "<F1>", function() prun.run(1) end)      -- run slot 1
vim.keymap.set("n", "<leader>m", prun.manage)                -- UI picker
```

---

## 📝 Examples

### 1 - Simple build & run

```
Slot 1 cmd : make
Slot 2 cmd : ./build/output
```

Run with `<F1>`, `<F2>` (or via `prun.manage`).

### 2 - Popup helper

```
Global default_pre   = tmux display-popup -w 80% -h 80% -T 'Scripts' 'bash'
Slot 3 cmd           = npm test
```

Each run opens a temporary popup, runs tests inside it, then closes.

### 3 - File-aware command

```
Slot 4 cmd = gcc -Wall %f -o %F.out && ./ %F.out
```

Compiles the **current buffer** and immediately executes the binary.

---

## 🔍 API reference (quick)

```lua
prun.setup(cfg)                -- configure
prun.run(slot)                 -- run slot (prompt if empty)
prun.edit(slot)                -- choose field & edit
prun.delete(slot)              -- clear slot
prun.list()                    -- table of all slots
prun.manage()                  -- TUIfy: select & act
prun.set_project_defaults(pre, post)
```

---

## ❓ FAQ

| Question                     | Answer                                                  |
| ---------------------------- | ------------------------------------------------------- |
| _Does it work without tmux?_ | No. The plugin checks `$TMUX` and errors out if absent. |
| _Where is the state stored?_ | One JSON-encoded `.prun` file per project.               |
| _Why 9 slots?_               | Convenience: numeric keymaps (`<F1>`-`<F9>`).           |

---
