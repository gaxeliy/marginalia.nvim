# marginalia.nvim

Margin notes for code review in Neovim: leave comments anchored to code lines,
navigate between them, and export everything to the system clipboard as
ready-to-paste LLM context.

## Features

- Comments are extmarks: `virt_lines` below the target line (the review-tool
  convention — a note on line 1 stays visible) + a `⚑` sign in the signcolumn.
- Multi-line notes get a range marker: a muted tint under the whole range
  (`range_marker = 'tint'`, the default), `│` continuators in the signcolumn
  (`'signs'`, low priority so gitsigns/LSP always win a contested line), or
  both (`'both'`). The note TEXT hangs BELOW the range END (the review-thread
  convention — GitHub/VSCode-style: the tinted block stays contiguous, the
  note reads after it), and the tint covers the LAST line of the range too
  (`end_row` semantics are exclusive; fixing it means L29-37 reads L37 tinted).
- Comment payloads live in a Lua table keyed by the extmark id (the same approach
  `vim.diagnostic` uses; extmarks have no `user_data` field in the set_extmark API).
- Review buffer (`<leader>Rb`): every note listed in one editable scratch
  buffer — tweak the wording freely, then `gy` copies the (edited) review
  copy to the system clipboard. There is NO two-way sync: the canonical
  notes stay in the store and are untouched by review-buffer edits.
- Line ranges: use visual mode (`v` / `V`) before `<leader>Ra`.
- Toggle comment visibility per buffer — clean reading, hidden notes still export.
- Floating preview of the note above the cursor (keybind, or `on_hover` via CursorHold).
- Optional JSON persistence: comments survive restarts and follow code edits
  (anchor = line number + anchor line's text, searched within ±25 lines).
- Export to the `+` register in `path/to/file.ext:42 comment text` form, with
  the commented code (`include_code`) and optional ±N context lines (`context_lines`).
- Telescope picker with in-picker actions (`<CR>` jump, `d`/`<C-d>` delete,
  `e`/`<C-e>` edit) and a quickfix fallback when Telescope is absent.
- Works in regular buffers and [diffview.nvim](https://github.com/sindrets/diffview.nvim) review buffers.

## Install

vim-plug:

```vim
Plug 'gaxeliy/marginalia.nvim'
lua require('marginalia').setup {}
```

lazy.nvim:

```lua
{
  'gaxeliy/marginalia.nvim',
  opts = {},
}
```

nvim's built-in `vim.pack` (kickstart-style):

```lua
vim.pack.add { 'https://github.com/gaxeliy/marginalia.nvim' }
require('marginalia').setup {}
```

## Default keymaps

| Keys         | Action                                                     |
|--------------|------------------------------------------------------------|
| `<leader>Ra` | add note (normal = current line, visual = range)           |
| `<leader>Re` | edit note on the current line                              |
| `<leader>Rc` | clear note on the current line                             |
| `<leader>RC` | clear ALL notes in the current project                          |
| `<leader>Rx` | export all notes to the clipboard                              |
| `<leader>Rp` | pick notes (Telescope / quickfix)                          |
| `<leader>Rb` | review buffer: all notes in one editable place             |
| `<leader>Rt` | toggle note visibility in the current buffer               |
| `<leader>Rv` | floating preview of the note on the current line           |
| `]R` / `[R`  | next / previous (visible) note in the buffer               |

`<leader>R` and `[R` were chosen because `<leader>g*`, `<leader>h*` (gitsigns),
`<leader>q*`, `<leader>s*`, `<leader>t*`, `<leader>u*` and `]c`/`[c` are already
taken in your config. Every mapping can be disabled by setting it to `false`.

## Setup options

```lua
require('marginalia').setup {
  keymaps = {
    add     = '<leader>Ra',
    edit    = '<leader>Re',
    clear   = '<leader>Rc',
    clear_all = '<leader>RC',
    export  = '<leader>Rx',
    pick    = '<leader>Rp',
    review  = '<leader>Rb',
    toggle  = '<leader>Rt',
    preview = '<leader>Rv',
    next    = ']R',
    prev    = '[R',
  },
  sign_text = '⚑',
  range_marker = 'tint',   -- multi-line note range: 'tint' (highlight under
                           -- the text, including the LAST line; 'end_row'
                           -- semantics are exclusive) | 'signs' ('│' in
                           -- the signcolumn, low priority) | 'both'
  include_code = false,  -- export appends the commented code lines ("  > ")
  context_lines = 0,     -- export adds ±N context lines ("  ~ "); overrides include_code
  persist = true,
  json_path = nil,       -- default: stdpath('data')/marginalia.json
  project_root = nil,    -- project scope (default: the directory nvim was
                         -- opened in — captured once at setup, so later
                         -- :cd never silently rescopes it)
  preview = {
    on_hover = false,    -- open the floating preview on CursorHold
    border = 'rounded',
  },
  telescope = {},        -- overrides for pickers.new()
}
```

`include_code` and `preview.on_hover` are opt-in (off by default).

### Project scope

The store is **one global JSON** (comments keyed by absolute file path), but
every "work on one project at a time" feature is scoped to the *current
project* — the directory nvim was opened in (`project_root`, captured at
setup). Export, the review buffer, the picker, and `<leader>RC` only ever see
notes whose files live under that root: notes from other projects stay in the
store but are invisible here and can never be wiped by accident. Override the
root when the opened directory is not the project root (monorepos, `nvim
--cmd 'cd ...'`, session managers): `project_root = '/abs/path/to/root'`.
`]R` / `[R` navigate within the current buffer, which is inherently in-scope.

## Public API

```lua
local mg = require('marginalia')
mg.add_comment()
mg.edit_comment()
mg.clear_current_comment()
mg.toggle_comments()
mg.preview_comment()
mg.next_comment() / mg.prev_comment()
mg.pick_comments()
mg.export_to_clipboard()
mg.delete_comment(comment) -- the object returned by get_all_comments
mg.get_all_comments()      -- current project only: { abspath, relpath, line, end_line, text, uid, bufnr? }
mg.clear_project_comments() -- wipe every note under project_root (the LLM cleanup button)
mg.flush_store()           -- synchronous store write (bypasses the debounce)
```

## Export format

```
lua/custom/plugins/diffview.lua:19 diffview_close should use a command
lua/custom/plugins/diffview.lua:20-25 this block duplicates the default config
```

With `include_code = true` each entry also gets the commented lines; with
`context_lines = 2` also two lines of context around each comment:

```
lua/marginalia/init.lua:88 namespace is created twice here
  ~ local cfg = vim.deepcopy(defaults)
  > local ns = vim.api.nvim_create_namespace('marginalia_comments')
  > local ns = vim.api.nvim_create_namespace('marginalia_comments')
  ~ -- namespace is created in setup()
```

## Persistence details

- File: `stdpath('data')/marginalia.json`, format `{"version":1,"files":{...}}`.
- Writes are crash-safe: the new content is written to a `tmp` file, the
  previous content is **copied** to `.bak` (the live store file is never
  momentarily absent, and a directory-shaped path is never renamed), then
  the `tmp` file is renamed over the store. A write that cannot be
  finalized notifies the user instead of failing silently.
- Foreign/corrupt store shapes are ignored: the plugin loads an empty
  store, never crashes, and preserves the unreadable bytes as
  `<path>.unreadable` before the next save can replace them.
- Two concurrent nvim instances both writing the store: last write wins
  (documented limitation; entries are self-healing from live extmarks).

## Testing

```bash
tests/run.sh        # PASS / SKIP / FAIL per suite, exit code 1 on failure
tests/mutate.sh     # mutation testing: 20 targeted mutations must all be killed
```

`core` and `fuzz` always run headlessly (plugin only). `telescope` and
`diffview` suites run when the respective plugins are installed and print a
`WARNING ... skipping` line otherwise. `mutate.sh` applies one behavior-
breaking change at a time to the module and expects the core suite to fail —
a surviving mutation marks a behavior no test pins. Every module fix lands
together with the test that pins it.

## Requirements

- Neovim >= 0.10
- Telescope (optional; quickfix fallback otherwise)
- A clipboard provider for `+` (X11/Wayland: `xclip`/`wl-copy`; see `:checkhealth provider`)
