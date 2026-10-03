-- marginalia.nvim — margin notes for code review + LLM context building.
--
-- Leave visual comments anchored to code lines (extmarks + virt_lines),
-- navigate between them, pick them in Telescope, and export everything
-- to the system clipboard as `path/to/file.ext:42 comment text`.
--
-- Optional JSON persistence: comments survive editor restarts (anchored
-- by line number + the anchor line's text, so they follow edits).
--
-- NOTE on data storage: extmarks do NOT support a `user_data` option in
-- nvim_buf_set_extmark (verified against the API and neovim sources).
-- Like vim.diagnostic itself, comment payloads live in a Lua sidecar
-- table keyed by the extmark id; extmarks only carry positions + visuals.
--
-- Requires Neovim >= 0.10. Telescope is optional (quickfix fallback).
--
-- Usage:
--   Plug 'gaxeliy/marginalia.nvim'
--   lua require('marginalia').setup {}

local M = {}

---@class marginalia.Config
local defaults = {
  -- Set any lhs to `false` (or nil) to disable that mapping.
  keymaps = {
    add     = '<leader>Ra', -- n + v (visual selection = line range)
    edit    = '<leader>Re', -- edit comment on current line
    clear   = '<leader>Rc', -- remove comment on current line
    clear_all = '<leader>RC', -- remove ALL comments in the current project
    export  = '<leader>Rx', -- copy all comments to the "+" register
    pick    = '<leader>Rp', -- Telescope picker (quickfix fallback)
    review  = '<leader>Rb', -- open every note in one editable buffer
    toggle  = '<leader>Rt', -- show/hide comment visuals in current buffer
    preview = '<leader>Rv', -- floating preview of the comment on current line
    next    = ']R',         -- jump to next (visible) comment in buffer
    prev    = '[R',         -- jump to previous (visible) comment in buffer
  },
  sign_text = '⚑',          -- sidebar marker (max 2 cells)
  range_marker = 'tint',    -- multi-line note range: 'tint' (highlight under
                            -- the text) | 'signs' ('│' in the signcolumn,
                            -- low priority) | 'both'
  include_code = false,     -- export: append the commented code lines
  context_lines = 0,        -- export: N extra lines of context around each
                            -- comment (0 = off); overrides include_code
  persist = true,           -- keep comments across sessions (JSON)
  json_path = nil,          -- default: stdpath('data')/marginalia.json
  project_root = nil,       -- project scope for clear-project; default: the
                            -- directory nvim was opened in (cwd at setup)
  preview = {               -- floating preview window
    on_hover = false,       -- open on CursorHold when a comment exists
    border = 'rounded',
  },
  telescope = {},           -- passed straight to pickers.new()
}

local cfg = vim.deepcopy(defaults)
local did_setup = false

-- namespace is created in setup(); every extmark lives in it.
local ns = nil

-- Namespace for range markers (tint highlight + '│' continuators). Separate
-- from `ns` on purpose: range extmarks must never be mistaken for comments
-- (find_comment_at_line scans `ns` and would "find" a bogus note on a
-- continuator row).
local range_ns = nil

-- ---------------------------------------------------------------------------
-- Comment payloads: extmark id -> { text, end_line }
-- extmarks keep position + visuals; this table keeps the payload.
-- ---------------------------------------------------------------------------

local comment_data = {}
local hidden = {} -- uid -> true when visuals are toggled off

-- uid -> { row -> extmark_id } range markers for that comment, per buffer
-- (two windows on one file are two bufnrs with independent uid sets).
local range_marks = {}

-- ---------------------------------------------------------------------------
-- Persistence store: abs_path -> { {line, end_line, text, anchor, uid} }
-- The store is the cross-session source of truth; live extmarks are the
-- in-session source of truth and sync positions back into the store.
-- File format: { version = 1, files = {...} } (atomic tmp+rename write).
-- ---------------------------------------------------------------------------

local store = { files = {} }
local next_uid = 1

local function encode_store()
  return vim.json.encode {
    version = 1,
    files = next(store.files) == nil and vim.empty_dict() or store.files,
  }
end

local function write_store()
  if not cfg.persist then return end
  local ok, data = pcall(encode_store)
  if not ok then
    vim.notify('marginalia: failed to encode store: ' .. tostring(data), vim.log.levels.ERROR)
    return
  end
  -- Atomic-ish write: tmp file + rename, so a crash mid-write cannot
  -- corrupt the store (the standard tmp + os.rename pattern).
  -- The previous content is COPIED to .bak first: the live store file is
  -- never momentarily absent, and a directory-shaped json_path is never
  -- renamed (renaming it would destroy the user's directory).
  local tmp = cfg.json_path .. '.tmp'
  local written = pcall(vim.fn.writefile, { data }, tmp)
  if not written then
    vim.notify('marginalia: failed to write store to ' .. cfg.json_path,
      vim.log.levels.ERROR)
    return
  end
  local f = io.open(cfg.json_path, 'r')
  if f then
    local prev = f:read '*a'
    f:close()
    if prev and #prev > 0 then
      local bf = io.open(cfg.json_path .. '.bak', 'w')
      if bf then
        bf:write(prev)
        bf:close()
      end
    end
  end
  local moved = os.rename(tmp, cfg.json_path)
  if not moved then
    os.remove(tmp) -- do not litter
    vim.notify('marginalia: failed to finalize store write to ' .. cfg.json_path,
      vim.log.levels.ERROR)
  end
end

-- Debounced save: edits can come in bursts (anchor re-sync, restore, ...).
-- A new schedule REPLACES the pending one (its timer is stopped), so the
-- last schedule is always the one that fires and a re-setup can never leave
-- a stale timer writing against a changed configuration.
local persist_timer = nil
local function schedule_persist()
  if not cfg.persist then return end
  if persist_timer then
    pcall(vim.loop.timer_stop, persist_timer)
  end
  persist_timer = vim.defer_fn(function()
    persist_timer = nil
    write_store()
  end, 300)
end

--- Flush the store to disk synchronously (bypasses the debounce).
function M.flush_store()
  write_store()
end

--- Internal: the active config once setup() has run (nil before that).
--- Used by the health check; not part of the public API.
function M._config()
  return did_setup and cfg or nil
end

-- Store file format: {"version": 1, "files": {...}}. Anything else
-- (corrupt JSON, arrays, foreign maps, future versions) is ignored: the
-- store simply loads empty, never crashing. Unreadable-but-existing files
-- are preserved byte-for-byte as "<path>.unreadable" before the next save
-- can replace them, so failed reads never destroy recoverable data.
local function extract_files(data)
  if type(data) ~= 'table' or data.version ~= 1 then return nil end
  return type(data.files) == 'table' and data.files or nil
end

local function read_json_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read '*a'
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok then return nil end
  return data
end

local function merge_entries(path, entries)
  if type(entries) ~= 'table' then return end
  local clean = {}
  for _, e in ipairs(entries) do
    if type(e) == 'table' and type(e.text) == 'string' then
      local uid = tonumber(e.uid) or 0
      if uid == 0 then
        uid = next_uid
        next_uid = next_uid + 1
      end
      local line = math.max(1, tonumber(e.line) or 1)
      local end_line = math.max(line, tonumber(e.end_line) or line)
      clean[#clean + 1] = {
        line = line,
        end_line = end_line,
        text = e.text,
        anchor = type(e.anchor) == 'string' and e.anchor or '',
        uid = uid,
      }
      next_uid = math.max(next_uid, uid + 1)
    end
  end
  if #clean > 0 then
    if store.files[path] == nil then
      store.files[path] = clean
    else
      for _, e in ipairs(clean) do
        table.insert(store.files[path], e)
      end
    end
  end
end

local function load_store()
  store.files = {}
  if not cfg.persist then return end -- persist=false: no cross-session state at all
  local f = io.open(cfg.json_path, 'r')
  if not f then return end
  local raw = f:read '*a'
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  local files = ok and extract_files(data) or nil
  if not files then
    -- Preserve the unreadable bytes so a later successful write cannot
    -- destroy potentially recoverable data.
    if cfg.persist and raw then
      local out = io.open(cfg.json_path .. '.unreadable', 'w')
      if out then
        out:write(raw)
        out:close()
      end
    end
    return
  end
  for path, entries in pairs(files) do
    if type(path) == 'string' then
      merge_entries(path, entries)
    end
  end
end

local function buffer_path(bufnr)
  return vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
end

-- Normal file buffers only: skips nofile/quickfix/etc. and pseudo-URIs.
-- diffview.nvim review buffers are regular named buffers, so they pass.
local function is_normal_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.bo[bufnr].buftype ~= '' then return false end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= '' and not name:match '^[a-zA-Z][a-zA-Z0-9+.-]*://'
end

local function to_relpath(path)
  local rel = vim.fn.fnamemodify(path, ':~:.')
  return rel ~= '' and rel or path
end

local function store_entry_index(path, uid)
  local entries = store.files[path]
  if not entries then return nil end
  for i, e in ipairs(entries) do
    if e.uid == uid then return i, e end
  end
  return nil
end

local function update_store_entry(path, uid, fields)
  local _, e = store_entry_index(path, uid)
  if not e then return end
  local changed = false
  for k, v in pairs(fields) do
    if e[k] ~= v then
      e[k] = v
      changed = true
    end
  end
  if changed then schedule_persist() end
end

-- Create-or-update a store entry from a live extmark. Missing uids are
-- re-created (self-healing after a manual store reset). The anchor is only
-- refreshed when `update_anchor` — for restore fallbacks the original
-- anchor must survive so it can match again after further edits.
local function sync_store_entry(path, bufnr, line, end_line, text, uid, update_anchor)
  store.files[path] = store.files[path] or {}
  local _, e = store_entry_index(path, uid)
  if not e then
    e = { line = line, end_line = end_line, text = text, anchor = '', uid = uid }
    table.insert(store.files[path], e)
  end
  local changed = false
  if e.line ~= line then e.line = line; changed = true end
  if e.end_line ~= end_line then e.end_line = end_line; changed = true end
  if e.text ~= text then e.text = text; changed = true end
  if update_anchor
    and bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    local anchor = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or e.anchor or ''
    if e.anchor ~= anchor then
      e.anchor = anchor
      changed = true
    end
  end
  if changed then schedule_persist() end
end

local function remove_store_entry(path, uid)
  local i = store_entry_index(path, uid)
  if not i then return end
  table.remove(store.files[path], i)
  if #store.files[path] == 0 then store.files[path] = nil end
  schedule_persist()
end

-- ---------------------------------------------------------------------------
-- Highlights
-- ---------------------------------------------------------------------------

local function define_highlights()
  -- Bright banner: vivid background + contrasting dark text.
  vim.api.nvim_set_hl(0, 'MarginaliaBanner', {
    default = true, bg = '#ffcc66', fg = '#111111', bold = true,
  })
  -- Sidebar sign: bright glyph, no background (blends into signcolumn).
  vim.api.nvim_set_hl(0, 'MarginaliaSign', {
    default = true, fg = '#ffcc66', bold = true,
  })
  -- Range tint for multi-line notes: a muted warm plaque UNDER the code
  -- (hl_mode='combine' keeps the syntax highlighting visible on top).
  vim.api.nvim_set_hl(0, 'MarginaliaRange', {
    default = true, bg = '#3a352b',
  })
end

-- ---------------------------------------------------------------------------
-- Extmark rendering
-- ---------------------------------------------------------------------------

local function build_virt_lines(text, line, end_line)
  local parts = vim.split(text, '\n', { plain = true })
  while #parts > 1 and parts[#parts] == '' do
    table.remove(parts)
  end
  local header = (' [L%d%s] '):format(line, end_line > line and ('-' .. end_line) or '')
  local vlines = {}
  for i, content in ipairs(parts) do
    vlines[i] = {
      { cfg.sign_text .. ' ', 'MarginaliaSign' },
      { i == 1 and header .. content or content, 'MarginaliaBanner' },
    }
  end
  return vlines
end

-- uid doubles as the extmark id, so extmark <-> payload <-> store lookups
-- are all the same integer. `visible = false` keeps the extmark (and its
-- live position tracking) but blanks the virt_lines and the sign.
--
-- Range markers visualize the span of a multi-line note (end_line > line).
-- The tint is a low-priority 'combine' highlight over the whole range; the
-- continuators are '│' signs on every non-anchor row. Both are optional via
-- cfg.range_marker and both are deliberately LOW priority: the signcolumn
-- shows ONE sign per line (highest priority wins), so our markers must
-- always yield to gitsigns/LSP rather than hide them.
local RANGE_PRIORITY = 1

local function clear_range_marks(bufnr, uid)
  local buf_marks = range_marks[bufnr]
  local marks = buf_marks and buf_marks[uid]
  if not marks then return end
  for _, id in pairs(marks) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, range_ns, id)
  end
  buf_marks[uid] = nil
  if not next(buf_marks) then range_marks[bufnr] = nil end
end

-- The range note TEXT hangs below the range END (row end_line-1): the
-- review-thread convention — the tinted block stays contiguous and the note
-- reads after it. Single-line notes keep their text on the comment extmark;
-- range notes carry it here (range_ns), so clear/hide/toggle manage it
-- together with the other range markers.
local function setup_range_marks(bufnr, uid, line, end_line, visible, text)
  clear_range_marks(bufnr, uid)
  if not visible or end_line <= line then return end
  local mode = cfg.range_marker or 'tint'
  local marks = {
    text = vim.api.nvim_buf_set_extmark(bufnr, range_ns, end_line - 1, 0, {
      virt_lines = build_virt_lines(text, line, end_line),
      virt_lines_above = false,
    }),
  }
  if mode == 'tint' or mode == 'both' then
    marks[line - 1] = vim.api.nvim_buf_set_extmark(bufnr, range_ns, line - 1, 0, {
      -- end_row is EXCLUSIVE: rows line-1..end_line-1 stay tinted, so the
      -- last range line IS included (end_line minus 1 would exclude it).
      end_row = end_line,
      hl_eol = true,
      hl_group = 'MarginaliaRange',
      hl_mode = 'combine',
      priority = RANGE_PRIORITY,
    })
  end
  if mode == 'signs' or mode == 'both' then
    for row = line, end_line - 1 do
      marks[row] = vim.api.nvim_buf_set_extmark(bufnr, range_ns, row, 0, {
        sign_text = '│',
        sign_hl_group = 'MarginaliaSign',
        priority = RANGE_PRIORITY,
      })
    end
  end
  range_marks[bufnr] = range_marks[bufnr] or {}
  range_marks[bufnr][uid] = marks
end

local function render_extmark(bufnr, uid, line, end_line, text, visible)
  comment_data[uid] = { text = text, end_line = end_line }
  -- Range notes render their text in range_ns below the range END
  -- (setup_range_marks); only single-line notes keep it here, below the line.
  local virt = visible and end_line == line and build_virt_lines(text, line, end_line) or {}
  local id = vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
    id = uid,
    virt_lines = virt,
    -- BELOW the line (the review-tool convention): a note on line 1 would
    -- land outside the renderable window area when placed above it.
    virt_lines_above = false,
    sign_text = visible and cfg.sign_text or '',
    sign_hl_group = visible and 'MarginaliaSign' or nil,
  })
  setup_range_marks(bufnr, uid, line, end_line, visible, text)
  return id
end

-- Returns extmark_id, payload for a comment anchored to `line` (1-indexed).
local function find_comment_at_line(bufnr, line)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  for _, m in ipairs(marks) do
    if m[2] == line - 1 then
      return m[1], comment_data[m[1]]
    end
  end
  return nil, nil
end

local function delete_comment(bufnr, uid)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, uid)
  clear_range_marks(bufnr, uid)
  comment_data[uid] = nil
  hidden[uid] = nil
end

-- ---------------------------------------------------------------------------
-- Restore (persistence): re-create extmarks when a file buffer is opened.
-- ---------------------------------------------------------------------------

-- If the stored line no longer matches its anchor text (file was edited),
-- look for the anchor within +/- 25 lines; otherwise keep the stored line.
-- Returns line, matched — the caller must not refresh the stored anchor
-- unless `matched`, or a fallback move would bake in the wrong anchor.
local function find_anchored_line(bufnr, wanted, anchor)
  if not anchor or anchor == '' then return wanted, false end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local from = math.max(0, wanted - 26)
  local to = math.min(line_count, wanted + 25)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from, to, false)
  for i, l in ipairs(lines) do
    if vim.trim(l) == vim.trim(anchor) then
      return from + i, true -- buffer lines are 1-indexed; `from` is 0-indexed
    end
  end
  return wanted, false
end

local function restore_buffer_comments(bufnr)
  if ns == nil or not is_normal_buffer(bufnr) or not cfg.persist then return end
  local path = buffer_path(bufnr)
  local entries = store.files[path]
  if not entries then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, range_ns, 0, -1)
  range_marks[bufnr] = nil
  for _, e in ipairs(entries) do
    local line, matched = find_anchored_line(bufnr, e.line, e.anchor)
    -- File may have shrank since the comment was stored: clamp to EOF.
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    line = math.max(1, math.min(line, line_count))
    local end_line = math.max(line, math.min(tonumber(e.end_line) or line, line_count))
    render_extmark(bufnr, e.uid, line, end_line, e.text, not hidden[e.uid])
    if line ~= e.line or end_line ~= e.end_line then
      sync_store_entry(path, bufnr, line, end_line, e.text, e.uid, matched)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Add a comment above the cursor line (or above the visual selection).
function M.add_comment()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_normal_buffer(bufnr) then
    vim.notify('marginalia: not a normal file buffer', vim.log.levels.WARN)
    return
  end
  local mode = vim.fn.mode()
  local visual = mode == 'v' or mode == 'V' or mode == '\22'
  local line, end_line
  if visual then
    -- `'<`/`'>` are unreliable while visual mode is still active (they lag
    -- behind the current selection); `v` mark + cursor are always correct.
    line = vim.fn.getpos 'v'[2]
    if line == 0 then line = vim.fn.line '.' end -- paranoia: unset `v` mark
    end_line = vim.fn.line '.'
    -- The range is captured: leave visual mode before prompting so the editor
    -- is back in normal mode after the note. vim.ui.input restores the mode it
    -- was invoked from, so exiting after the callback would be undone.
    vim.cmd.normal({ args = { '\27' }, bang = true })
  else
    line, end_line = vim.fn.line '.', vim.fn.line '.'
  end
  if line > end_line then line, end_line = end_line, line end

  -- One note per anchor line: find/edit/clear/preview all address the
  -- (single) comment anchored at a line, so a second one would be dead.
  if find_comment_at_line(bufnr, line) then
    vim.notify('marginalia: a note already exists on this line', vim.log.levels.WARN)
    return
  end

  local range_label = ('L%d%s'):format(line, end_line > line and ('-' .. end_line) or '')
  vim.ui.input({ prompt = ('Margin note (%s): '):format(range_label) }, function(text)
    if not text or text == '' then return end
    local uid = next_uid
    next_uid = next_uid + 1
    render_extmark(bufnr, uid, line, end_line, text, true)

    local path = buffer_path(bufnr)
    store.files[path] = store.files[path] or {}
    table.insert(store.files[path], {
      line = line,
      end_line = end_line,
      text = text,
      anchor = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or '',
      uid = uid,
      ts = os.time(),
    })
    schedule_persist()
  end)
end

--- Edit the comment anchored to the current line (text pre-filled).
--- <C-c> (interrupt) is treated as cancel, not an error.
function M.edit_comment()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.fn.line '.'
  local id, payload = find_comment_at_line(bufnr, line)
  if not id then
    vim.notify('marginalia: no comment on line ' .. line, vim.log.levels.WARN)
    return
  end
  local CANCEL = '\27'
  local ok, new_text = pcall(vim.fn.input, {
    prompt = 'Edit margin note: ',
    default = payload.text or '',
    cancelreturn = CANCEL,
  })
  if not ok or new_text == CANCEL or new_text == '' or new_text == payload.text then
    return -- cancelled or interrupted: keep the note as it was
  end
  local end_line = tonumber(payload.end_line) or line
  render_extmark(bufnr, id, line, end_line, new_text, not hidden[id])
  update_store_entry(buffer_path(bufnr), id, { text = new_text })
end

--- Remove the comment anchored to the current line.
function M.clear_current_comment()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.fn.line '.'
  local id = find_comment_at_line(bufnr, line)
  if not id then
    vim.notify('marginalia: no comment on line ' .. line, vim.log.levels.WARN)
    return
  end
  delete_comment(bufnr, id)
  remove_store_entry(buffer_path(bufnr), id)
  vim.notify('marginalia: comment removed')
end

-- Does `path` (an absolute file path) belong to the project rooted at
-- `root`? Prefix match with the trailing separator: /proj matches
-- /proj/a.lua but NOT /proj-other/a.lua (the separator draws the boundary).
local function in_project(path, root)
  if not path or path == '' then return false end
  path = vim.fs.normalize(path)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

--- Remove EVERY comment in the current PROJECT — the files under the
--- directory nvim was opened in (cfg.project_root, default = cwd at setup) —
--- in one go: live extmarks, range marks, and store entries. The "sent it
--- to the LLM, now clean up" button: comments belonging to other projects
--- (files outside the root) are untouched.
function M.clear_project_comments()
  local root = vim.fs.normalize(cfg.project_root or vim.fn.getcwd())
  local removed = 0
  local seen = {} -- project paths that are loaded (counted via extmarks)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and is_normal_buffer(bufnr) then
      local path = buffer_path(bufnr)
      if in_project(path, root) then
        seen[path] = true
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
        for _, m in ipairs(marks) do
          delete_comment(bufnr, m[1])
          remove_store_entry(path, m[1])
          removed = removed + 1
        end
      end
    end
  end
  -- store-only comments (files NOT loaded) under the root
  for path, entries in pairs(store.files) do
    if in_project(path, root) and not seen[path] then
      removed = removed + #entries
    end
  end
  if removed == 0 then
    vim.notify('marginalia: no comments in this project', vim.log.levels.WARN)
    return
  end
  -- drop the store entries of every project path (loaded ones were already
  -- removed per-id by remove_store_entry, which nils empty lists)
  for path, _ in pairs(store.files) do
    if in_project(path, root) then store.files[path] = nil end
  end
  schedule_persist()
  vim.notify(('marginalia: %d comment(s) removed'):format(removed))
end

--- Toggle visibility of the comment visuals in the current buffer.
--- Hidden comments keep their positions and still count for export/pick,
--- but are invisible and skipped by next/prev navigation.
function M.toggle_comments()
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  if #marks == 0 then
    vim.notify('marginalia: no comments in this buffer', vim.log.levels.WARN)
    return
  end
  local any_hidden = false
  for _, m in ipairs(marks) do
    if hidden[m[1]] then
      any_hidden = true
      break
    end
  end
  -- Semantics: if anything is hidden, this press shows everything;
  -- otherwise (everything visible) it hides everything.
  local visible = any_hidden
  for _, m in ipairs(marks) do
    local payload = comment_data[m[1]]
    if payload then
      render_extmark(bufnr, m[1], m[2] + 1, payload.end_line, payload.text, visible)
      if visible then
        hidden[m[1]] = nil
      else
        hidden[m[1]] = true
      end
    end
  end
  vim.notify(visible and 'marginalia: comments shown' or 'marginalia: comments hidden')
end

-- ---------------------------------------------------------------------------
-- Floating preview
-- ---------------------------------------------------------------------------

local preview_win = nil
local preview_buf = nil

local function close_preview()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
  end
  preview_win = nil
  if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
    vim.api.nvim_buf_delete(preview_buf, { force = true })
  end
  preview_buf = nil
end

--- Show the comment anchored to the current line in a floating window
--- above the cursor. Closes on cursor move / leaving the buffer / insert.
function M.preview_comment()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.fn.line '.'
  local id, payload = find_comment_at_line(bufnr, line)
  if not id then
    vim.notify('marginalia: no comment on line ' .. line, vim.log.levels.WARN)
    return
  end
  close_preview()

  local path = buffer_path(bufnr)
  local end_line = tonumber(payload.end_line) or line
  local range = end_line > line and (line .. '-' .. end_line) or tostring(line)
  local header = ('%s:%s'):format(to_relpath(path), range)

  local content = { header, '' }
  for _, text_line in ipairs(vim.split(payload.text, '\n', { plain = true })) do
    content[#content + 1] = text_line
  end
  content = vim.list_slice(content, 1, math.min(#content, 20))

  local width = 0
  for _, l in ipairs(content) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.max(20, math.min(width + 2, 100))

  local pb = vim.api.nvim_create_buf(false, true)
  vim.bo[pb].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(pb, 0, -1, false, content)
  vim.bo[pb].modified = false
  -- Banner highlight on the header line.
  vim.api.nvim_buf_set_extmark(pb, ns, 0, 0, {
    end_row = 0, end_col = #header,
    hl_group = 'MarginaliaBanner',
  })

  local win = vim.api.nvim_open_win(pb, false, {
    relative = 'cursor',
    anchor = 'SW',
    row = -1,
    col = 0,
    width = width,
    height = math.max(1, math.min(#content, 20)),
    border = (cfg.preview and cfg.preview.border) or 'rounded',
    style = 'minimal',
  })
  vim.wo[win].wrap = true
  preview_win = win
  preview_buf = pb

  local group = vim.api.nvim_create_augroup('MarginaliaPreview', { clear = true })
  local function dismiss()
    close_preview()
    return true -- delete the autocmds
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufLeave', 'InsertEnter' }, {
    group = group,
    buffer = bufnr,
    once = true,
    callback = dismiss,
  })
end

-- ---------------------------------------------------------------------------
-- Collection / export
-- ---------------------------------------------------------------------------

--- Collect every comment in the CURRENT PROJECT.
--- The persistence store is one global file for every reviewed project, but
--- the review buffer, picker, export, and clipboard copy all represent ONE
--- project at a time — the directory nvim was opened in (cfg.project_root).
--- Loaded buffers are scanned via extmarks (positions always fresh), unloaded
--- files come from the persistence store. Hidden comments are included
--- (toggling only hides visuals).
--- Returns a list sorted by path, then line:
---   { abspath, relpath, line, end_line, text, uid, bufnr? }
function M.get_all_comments()
  local comments = {}
  local seen_paths = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and is_normal_buffer(bufnr) then
      local path = buffer_path(bufnr)
      seen_paths[path] = true
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      for _, m in ipairs(marks) do
        local payload = comment_data[m[1]]
        if payload then
          local line = m[2] + 1
          local end_line = math.max(line, tonumber(payload.end_line) or line)
          comments[#comments + 1] = {
            bufnr = bufnr,
            abspath = path,
            relpath = to_relpath(path),
            line = line,
            end_line = end_line,
            text = payload.text,
            uid = m[1],
          }
          -- Keep the store's positions in sync with the live extmarks
          -- (also re-creates entries lost from the store, self-healing).
          sync_store_entry(path, bufnr, line, end_line, payload.text, m[1], true)
        end
      end
    end
  end

  for path, entries in pairs(store.files) do
    if not seen_paths[path] then
      for _, e in ipairs(entries) do
        comments[#comments + 1] = {
          abspath = path,
          relpath = to_relpath(path),
          line = e.line,
          end_line = e.end_line,
          text = e.text,
          uid = e.uid,
        }
      end
    end
  end

  -- Project scope: cfg.project_root (the directory nvim was opened in).
  -- Comments whose file is outside the root are invisible here — and the
  -- wipe (clear_project_comments) honors the same boundary, so "delete all"
  -- can never eat another project's notes.
  local root = vim.fs.normalize(cfg.project_root or vim.fn.getcwd())
  local scoped = {}
  for _, c in ipairs(comments) do
    if in_project(c.abspath, root) then scoped[#scoped + 1] = c end
  end
  comments = scoped

  table.sort(comments, function(a, b)
    if a.abspath ~= b.abspath then return a.abspath < b.abspath end
    return a.line < b.line
  end)
  return comments
end

-- Commented range lines + cfg.context_lines of surrounding context.
local function code_context(c)
  local lines = {}
  if c.bufnr and vim.api.nvim_buf_is_valid(c.bufnr) and vim.api.nvim_buf_is_loaded(c.bufnr) then
    lines = vim.api.nvim_buf_get_lines(c.bufnr, 0, -1, false)
  else
    local ok, read = pcall(vim.fn.readfile, c.abspath)
    if not ok then return nil end
    lines = read
  end
  local total = #lines
  local before = {}
  for i = math.max(1, c.line - cfg.context_lines), c.line - 1 do
    before[#before + 1] = lines[i]
  end
  local code = {}
  for i = c.line, math.min(c.end_line, total) do
    code[#code + 1] = lines[i]
  end
  local after = {}
  for i = c.end_line + 1, math.min(total, c.end_line + cfg.context_lines) do
    after[#after + 1] = lines[i]
  end
  return { before = before, code = code, after = after }
end

local function range_label(c)
  return c.end_line > c.line and (c.line .. '-' .. c.end_line) or tostring(c.line)
end

--- Copy all comments to the "+" (system clipboard) register:
---   path/to/file.ext:42 comment text
---   path/to/file.ext:42-45 multi line comment
--- cfg.include_code = true appends the commented code as "  > ..." lines;
--- cfg.context_lines > 0 adds context as "  ~ ..." lines around them.
--- When no clipboard provider is available, the text is additionally
--- placed in the unnamed register (fallback) and the user is warned;
--- with a working provider the unnamed register is left untouched.
local function clipboard_available()
  if vim.g.clipboard ~= nil then return true end -- user-defined provider
  local ok, exe = pcall(vim.fn['provider#clipboard#Executable'])
  return ok and type(exe) == 'string' and exe ~= ''
end

function M.export_to_clipboard()
  local comments = M.get_all_comments()
  if #comments == 0 then
    vim.notify('marginalia: no comments to export', vim.log.levels.WARN)
    return
  end
  local want_code = cfg.include_code or (cfg.context_lines or 0) > 0
  local out = {}
  for _, c in ipairs(comments) do
    out[#out + 1] = ('%s:%s %s'):format(c.relpath, range_label(c), (c.text:gsub('[\r\n]+', ' ')))
    if want_code then
      local ctx = code_context(c)
      if ctx then
        for _, l in ipairs(ctx.before) do out[#out + 1] = '  ~ ' .. l end
        for _, l in ipairs(ctx.code) do out[#out + 1] = '  > ' .. l end
        for _, l in ipairs(ctx.after) do out[#out + 1] = '  ~ ' .. l end
      end
    end
  end
  local text = table.concat(out, '\n')
  vim.fn.setreg('+', text)
  if not clipboard_available() then
    vim.fn.setreg('"', text) -- fallback: keep the text reachable without a provider
    vim.notify(
      'marginalia: clipboard provider not found, text is only in register "+" '
        .. '(run :checkhealth provider)',
      vim.log.levels.WARN
    )
    return
  end
  vim.notify(('marginalia: %d comment(s) copied to clipboard'):format(#comments))
end

-- ---------------------------------------------------------------------------
-- Navigation / picker
-- ---------------------------------------------------------------------------

local function jump_to_comment(c)
  if c.bufnr and vim.api.nvim_buf_is_valid(c.bufnr) then
    for _, win in ipairs(vim.fn.win_findbuf(c.bufnr)) do
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { c.line, 0 })
      vim.cmd 'normal! zz'
      return
    end
    vim.api.nvim_set_current_buf(c.bufnr)
  else
    local ok = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(c.abspath))
    if not ok then
      vim.notify('marginalia: cannot open ' .. c.abspath, vim.log.levels.WARN)
      return
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { c.line, 0 })
  vim.cmd 'normal! zz'
end

--- Delete a comment object (as returned by get_all_comments).
function M.delete_comment(c)
  if c.bufnr and vim.api.nvim_buf_is_valid(c.bufnr) then
    delete_comment(c.bufnr, c.uid)
  end
  hidden[c.uid] = nil
  comment_data[c.uid] = nil
  remove_store_entry(c.abspath, c.uid)
  vim.notify('marginalia: comment deleted')
end

local function jump_adjacent(direction)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})) do
    if not hidden[m[1]] then
      lines[#lines + 1] = m[2] + 1
    end
  end
  if #lines == 0 then
    vim.notify('marginalia: no comments in this buffer', vim.log.levels.WARN)
    return
  end
  table.sort(lines)
  local cursor = vim.fn.line '.'
  local target
  if direction > 0 then
    for _, l in ipairs(lines) do
      if l > cursor then target = l break end
    end
    target = target or lines[1] -- wrap around
  else
    for i = #lines, 1, -1 do
      if lines[i] < cursor then target = lines[i] break end
    end
    target = target or lines[#lines] -- wrap around
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd 'normal! zz'
end

function M.next_comment() jump_adjacent(1) end

function M.prev_comment() jump_adjacent(-1) end

-- Shared quickfix fallback: used when Telescope is missing OR fails to
-- start (e.g. a telescope.nvim version that does not support this Neovim).
local function open_quickfix(comments)
  local qf = {}
  for _, c in ipairs(comments) do
    qf[#qf + 1] = {
      filename = c.abspath,
      lnum = c.line,
      text = (c.text:gsub('[\r\n]+', ' ')),
    }
  end
  vim.fn.setqflist(qf, 'r')
  vim.fn.setqflist({}, 'a', { title = 'Marginalia: review comments' })
  vim.cmd 'copen'
end

--- Telescope picker over all comments (falls back to the quickfix list).
--- Bindings inside the picker: <CR> jump, d/<C-d> delete, e/<C-e> edit.
function M.pick_comments()
  local comments = M.get_all_comments()
  if #comments == 0 then
    vim.notify('marginalia: no comments yet', vim.log.levels.WARN)
    return
  end

  local ok_telescope, pickers = pcall(require, 'telescope.pickers')
  if not ok_telescope then
    vim.notify('marginalia: telescope.nvim not found — opened the quickfix list instead',
      vim.log.levels.WARN)
    open_quickfix(comments)
    return
  end

  local finders = require 'telescope.finders'
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local conf = require('telescope.config').values

  local function act(action)
    return function(prompt_bufnr)
      local entry = action_state.get_selected_entry()
      actions.close(prompt_bufnr)
      if not entry then return end
      if action == 'jump' then
        jump_to_comment(entry.value)
      elseif action == 'delete' then
        M.delete_comment(entry.value)
      elseif action == 'edit' then
        jump_to_comment(entry.value)
        M.edit_comment()
      end
    end
  end

  local ok_pick, err = pcall(function()
    pickers.new(vim.tbl_deep_extend('force', {
      prompt_title = 'Marginalia: Review Comments',
      finder = finders.new_table {
        results = comments,
        entry_maker = function(c)
          local label = ('%s:%s %s'):format(c.relpath, range_label(c),
            (c.text:gsub('[\r\n]+', ' ')))
          return {
            value = c,
            display = label,
            ordinal = label,
            filename = c.abspath,
            lnum = c.line,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = conf.grep_previewer {},
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(act('jump'))
        map('n', 'd', act('delete'))
        map('n', 'e', act('edit'))
        map('i', '<C-d>', act('delete'))
        map('i', '<C-e>', act('edit'))
        return true
      end,
    }, cfg.telescope or {})):find()
  end)
  if not ok_pick then
    vim.notify('marginalia: telescope failed to start (' .. tostring(err)
      .. ') — opened the quickfix list instead', vim.log.levels.WARN)
    open_quickfix(comments)
  end
end

-- ---------------------------------------------------------------------------
-- Review buffer: every note in one editable scratch buffer.
-- Deliberately NO two-way sync — the review copy is a draft the user edits
-- freely (tweaking wording before pasting it into an LLM); the canonical
-- notes stay in the store and are untouched by edits made here.
-- ---------------------------------------------------------------------------

local HEADER_FMT = '=== %s:%d%s ==='

local function format_review(comments)
  local out = {}
  for _, c in ipairs(comments) do
    out[#out + 1] = HEADER_FMT:format(c.relpath, c.line,
      c.end_line > c.line and ('-' .. c.end_line) or '')
    for _, l in ipairs(vim.split(c.text, '\n', { plain = true })) do
      out[#out + 1] = l
    end
    out[#out + 1] = ''
  end
  return out
end

local review_buf = nil

local function review_header_path(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
  local rel, start = line:match('^=== (.+):(%d+)')
  if not rel then return nil end
  -- resolve the header's relpath to an absolute path against the live notes
  for _, c in ipairs(M.get_all_comments()) do
    if c.relpath == rel then return c.abspath, tonumber(start) end
  end
  return vim.fs.normalize(vim.fn.fnamemodify(rel, ':p')), tonumber(start)
end

local function close_review_buffer()
  if review_buf and vim.api.nvim_buf_is_valid(review_buf) then
    vim.api.nvim_buf_delete(review_buf, { force = true })
  end
  review_buf = nil
end

--- Open (or focus) the review buffer listing every note. Unsaved edits in
--- the review copy are preserved on re-open; an unmodified copy is
--- re-rendered from the canonical store.
function M.open_review()
  local comments = M.get_all_comments()
  if #comments == 0 then
    vim.notify('marginalia: no comments yet', vim.log.levels.WARN)
    return
  end

  local lines = format_review(comments)
  local exists = review_buf and vim.api.nvim_buf_is_valid(review_buf)
  if exists then
    -- focus an existing window, or open one for the hidden buffer
    local focused = false
    for _, win in ipairs(vim.fn.win_findbuf(review_buf)) do
      vim.api.nvim_set_current_win(win)
      focused = true
      break
    end
    if not focused then
      pcall(vim.cmd, 'sbuffer ' .. review_buf)
    end
    if vim.bo[review_buf].modified then
      vim.notify('marginalia: review copy has unsaved edits — kept as edited',
        vim.log.levels.WARN)
      return
    end
  else
    -- a listed, plain buffer: API set_lines must set 'modified' (nofile
    -- buffers never do), so unsaved review edits can be detected on re-open
    review_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[review_buf].bufhidden = 'hide'
    vim.bo[review_buf].swapfile = false
    vim.api.nvim_buf_set_name(review_buf, 'marginalia://review')
    pcall(vim.cmd, 'sbuffer ' .. review_buf)
  end

  vim.bo[review_buf].modifiable = true
  vim.api.nvim_buf_set_lines(review_buf, 0, -1, false, lines)
  vim.bo[review_buf].modified = false

  -- buffer-local keys: q close, gy copy the review copy, CR jump to the
  -- note under the cursor (descs feed which-key)
  vim.keymap.set('n', 'q', '<cmd>close<cr>',
    { buffer = review_buf, silent = true, desc = 'marginalia: close review buffer' })
  vim.keymap.set('n', 'gy', function()
    local ls = vim.api.nvim_buf_get_lines(review_buf, 0, -1, false)
    vim.fn.setreg('+', table.concat(ls, '\n'))
    vim.notify(('marginalia: review copy (%d lines) copied to clipboard')
      :format(#ls))
  end, { buffer = review_buf, silent = true,
    desc = 'marginalia: copy review copy to clipboard' })
  vim.keymap.set('n', '<CR>', function()
    local abspath, line = review_header_path(review_buf, vim.fn.line '.')
    if abspath then
      vim.cmd 'close'
      jump_to_comment({ abspath = abspath, line = line or 1 })
    end
  end, { buffer = review_buf, silent = true,
    desc = 'marginalia: jump to note' })
  vim.api.nvim_create_autocmd('BufUnload', {
    buffer = review_buf,
    once = true,
    callback = function() review_buf = nil end,
  })
end

--- Copy the whole review buffer (as edited by the user) to the "+" register.
function M.copy_review()
  if not (review_buf and vim.api.nvim_buf_is_valid(review_buf)) then
    vim.notify('marginalia: no review buffer open', vim.log.levels.WARN)
    return
  end
  local ls = vim.api.nvim_buf_get_lines(review_buf, 0, -1, false)
  vim.fn.setreg('+', table.concat(ls, '\n'))
  vim.notify(('marginalia: review copy (%d lines) copied to clipboard'):format(#ls))
end

--- Close the review buffer, discarding the review copy.
function M.close_review()
  close_review_buffer()
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local mapped_keys = {} -- { {mode, lhs} } — everything the last setup() mapped

local function setup_keymaps()
  -- Re-setup must not accumulate stale mappings (config reloads, tests).
  for _, mk in ipairs(mapped_keys) do
    pcall(vim.keymap.del, mk[1], mk[2])
  end
  mapped_keys = {}
  local km = cfg.keymaps or {}
  local function map(lhs, rhs, modes, desc)
    if not lhs then return end
    local mode_list = type(modes) == 'table' and modes or { modes or 'n' }
    vim.keymap.set(mode_list, lhs, rhs, { desc = desc, silent = true })
    for _, mode in ipairs(mode_list) do
      mapped_keys[#mapped_keys + 1] = { mode, lhs }
    end
  end
  map(km.add, M.add_comment, { 'n', 'v' }, '[R]eview: add margin note')
  map(km.edit, M.edit_comment, 'n', '[R]eview: edit margin note')
  map(km.clear, M.clear_current_comment, 'n', '[R]eview: clear margin note')
  map(km.clear_all, M.clear_project_comments, 'n', '[R]eview: clear ALL comments in project')
  map(km.export, M.export_to_clipboard, 'n', '[R]eview: export to clipboard')
  map(km.pick, M.pick_comments, 'n', '[R]eview: pick comments')
  map(km.review, M.open_review, 'n', '[R]eview: open the review buffer')
  map(km.toggle, M.toggle_comments, 'n', '[R]eview: toggle comment visibility')
  map(km.preview, M.preview_comment, 'n', '[R]eview: preview comment')
  map(km.next, M.next_comment, 'n', '[R]eview: next comment')
  map(km.prev, M.prev_comment, 'n', '[R]eview: previous comment')

  -- which-key group label (no-op if which-key is absent).
  local ok_wk, wk = pcall(require, 'which-key')
  if ok_wk and wk.add then
    wk.add { { '<leader>R', group = '[R]eview (marginalia)' } }
  end
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup('Marginalia', { clear = true })
  -- Re-apply styles when the colorscheme changes.
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_highlights,
  })
  -- Restore persisted comments when a file buffer is opened.
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(args) restore_buffer_comments(args.buf) end,
  })
  -- Optional floating preview on hover.
  if cfg.preview and cfg.preview.on_hover then
    vim.api.nvim_create_autocmd('CursorHold', {
      group = group,
      callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        if not is_normal_buffer(bufnr) then return end
        local _, payload = find_comment_at_line(bufnr, vim.fn.line '.')
        if payload then
          M.preview_comment()
        else
          close_preview()
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = write_store,
  })
end

--- Configure the plugin.
---   require('marginalia').setup { include_code = true }
function M.setup(user_opts)
  did_setup = true
  cfg = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_opts or {})
  if type(cfg.keymaps) ~= 'table' then
    cfg.keymaps = {} -- keymaps = false => no mappings at all
  end
  cfg.json_path = cfg.json_path
    or vim.fs.joinpath(vim.fn.stdpath 'data', 'marginalia.json')
  -- "the directory nvim was opened in": capture once at setup, so later
  -- :cd / autochdir never silently rescopes the project-clear button.
  cfg.project_root = vim.fs.normalize(cfg.project_root or vim.fn.getcwd())

  ns = vim.api.nvim_create_namespace 'marginalia_comments'
  range_ns = vim.api.nvim_create_namespace 'marginalia_range'

  if cfg.range_marker ~= 'tint' and cfg.range_marker ~= 'signs'
    and cfg.range_marker ~= 'both' then
    vim.notify("marginalia: unknown range_marker '" .. tostring(cfg.range_marker)
      .. "', falling back to 'tint'", vim.log.levels.WARN)
    cfg.range_marker = 'tint'
  end

  define_highlights()
  load_store()
  setup_autocmds()
  setup_keymaps()

  -- Buffers that are already open when setup() runs.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      restore_buffer_comments(bufnr)
    end
  end
end

return M
