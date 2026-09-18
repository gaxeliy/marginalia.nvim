-- marginalia.nvim core test suite — fully synchronous, headless.
-- No time dependency for state assertions: debounced writes are bypassed via
-- M.flush_store(); the ONE async behavior (the debounce landing on disk) is
-- asserted through a vim.wait predicate whose pass condition is the file
-- itself. Every assertion verifies exactly what its message names.
local WARNINGS, ERRORS = {}, {}
local function reset_warnings()
  local n = #WARNINGS
  WARNINGS = {}
  return n
end
local function reset_errors()
  local n = #ERRORS
  ERRORS = {}
  return n
end
vim.notify = function(msg, lvl)
  if lvl == vim.log.levels.WARN then WARNINGS[#WARNINGS + 1] = msg end
  if lvl == vim.log.levels.ERROR then ERRORS[#ERRORS + 1] = msg end
  print(('[NOTIFY %s] %s'):format(tostring(lvl), msg))
end

local plugin_dir = vim.fn.getcwd()
vim.opt.runtimepath:prepend(plugin_dir)
local DATA = '/tmp/opencode/mg_data'
-- Bootstrap: wipe DATA and its store-write siblings (.bak/.tmp/.unreadable
-- live NEXT to the path, so leftover siblings from previous runs would
-- otherwise poison failure-path tests).
vim.fn.delete(DATA, 'rf')
vim.fn.delete(DATA .. '.bak', 'rf')
vim.fn.delete(DATA .. '.tmp', 'rf')
vim.fn.delete(DATA .. '.unreadable', 'rf')
vim.fn.mkdir(DATA, 'p')
-- Scope: project_root defaults to the cwd at setup, and get_all_comments /
-- clear_project_comments / export / review / pick all honor it. The suite
-- plays the role of "nvim opened in the fixture directory".
vim.fn.chdir(DATA)

local mg = require('marginalia')
local ns = vim.api.nvim_create_namespace('marginalia_comments')
-- Hoisted: range namespace + helpers usable by both Phase 4 and Phase 13.
local range_ns = vim.api.nvim_create_namespace 'marginalia_range'
local function range_extmarks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, range_ns, 0, -1, {})
end
local function range_details(buf, id)
  local res = vim.api.nvim_buf_get_extmark_by_id(buf, range_ns, id, { details = true })
  return res and res[3] or {}
end

local function write_file(path, content)
  local fh = io.open(path, 'w')
  fh:write(content)
  fh:close()
end

local function read_store(json_path)
  local fh = io.open(json_path, 'r')
  if not fh then return nil end
  local decoded = vim.json.decode(fh:read '*a')
  fh:close()
  return decoded
end

local function read_raw(path)
  local fh = io.open(path, 'r')
  if not fh then return nil end
  local raw = fh:read '*a'
  fh:close()
  return raw
end

local function float_windows()
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= '' then
      out[#out + 1] = w
    end
  end
  return out
end

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

local function find_review_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == 'marginalia://review' then return b end
  end
  return nil
end

-- ===========================================================================
-- PHASE 0: setup option guards ({field = false} never crashes) + the empty
-- store must encode "files":{} (an OBJECT) — the first-release encode bug
-- ===========================================================================
local ok0, err0 = pcall(mg.setup,
  { persist = false, keymaps = false, telescope = false, preview = false,
    json_path = DATA .. '/guards.json' })
assert(ok0, 'setup with boolean keymaps/telescope/preview must not crash: ' .. tostring(err0))

mg.setup { persist = true, json_path = DATA .. '/empty_store.json' }
mg.flush_store()
local raw_empty = read_raw(DATA .. '/empty_store.json')
assert(raw_empty:find('"files":{}', 1, true),
  'empty store must encode files as an object, raw: ' .. raw_empty)
assert(not raw_empty:find('"files":%[%]', 1, false),
  'empty store must not encode files as an array, raw: ' .. raw_empty)
-- .bak contract on a controlled sequence: the first write has nothing
-- previous -> no .bak; the next write backs up the previous content
assert(io.open(DATA .. '/empty_store.json.bak', 'r') == nil,
  'first write: no .bak yet (nothing previous to back up)')
mg.flush_store()
assert(read_raw(DATA .. '/empty_store.json.bak') == raw_empty,
  'the second write backs up the previous store byte-for-byte')

-- ===========================================================================
-- PHASE 1: identity + guards/refusals (nothing loaded, store empty,
-- persist=false so no cross-session state is involved at all)
-- ===========================================================================
mg.setup { persist = false, keymaps = false, json_path = DATA .. '/p1.json' }
assert(vim.api.nvim_get_namespaces()['marginalia_comments'] ~= nil, 'namespace name')
assert(vim.fn.hlexists('MarginaliaBanner') > 0, 'MarginaliaBanner hl')
assert(vim.fn.hlexists('MarginaliaSign') > 0, 'MarginaliaSign hl')
assert(#mg.get_all_comments() == 0, 'fresh store must be empty')

local path = DATA .. '/demo.lua'
write_file(path, 'local a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 4\nlocal e = 5\n')
vim.cmd('edit ' .. vim.fn.fnameescape(path))
local bufnr = vim.api.nvim_get_current_buf()

-- 1a. nofile buffer refused: warn + no extmark
local nofile_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_option_value('buftype', 'nofile', { buf = nofile_buf })
vim.api.nvim_set_current_buf(nofile_buf)
reset_warnings()
mg.add_comment()
assert(reset_warnings() == 1, 'add in nofile buffer must warn')
assert(#vim.api.nvim_buf_get_extmarks(nofile_buf, ns, 0, -1, {}) == 0,
  'no extmark in nofile buffer')

-- 1b. unnamed buffer refused
local unnamed = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(unnamed)
reset_warnings()
mg.add_comment()
assert(reset_warnings() == 1, 'add in unnamed buffer must warn')
assert(#vim.api.nvim_buf_get_extmarks(unnamed, ns, 0, -1, {}) == 0,
  'no extmark in unnamed buffer')
vim.api.nvim_buf_delete(unnamed, { force = true })

-- 1c. URI-like name refused
local uri_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(uri_buf, 'fugitive://repo/x.lua')
vim.api.nvim_set_current_buf(uri_buf)
reset_warnings()
mg.add_comment()
assert(reset_warnings() == 1, 'add in URI-scheme buffer must warn')
vim.api.nvim_buf_delete(uri_buf, { force = true })

-- 1d. zero-comment actions: warn, no crash, no side effects
reset_warnings()
mg.clear_current_comment()
assert(reset_warnings() == 1, 'clear with no comment must warn')
mg.edit_comment()
assert(reset_warnings() == 1, 'edit with no comment must warn')
mg.next_comment()
assert(reset_warnings() == 1, 'next with no comments must warn')
mg.prev_comment()
assert(reset_warnings() == 1, 'prev with no comments must warn')
mg.toggle_comments()
assert(reset_warnings() == 1, 'toggle with no comments must warn')
mg.export_to_clipboard()
assert(reset_warnings() == 1, 'export with no comments must warn')
mg.preview_comment()
assert(reset_warnings() == 1, 'preview with no comment must warn')
assert(#float_windows() == 0, 'preview with no comment must not open a window')
vim.fn.setqflist({}, 'r')
mg.pick_comments()
assert(reset_warnings() == 1, 'pick with no comments must warn')
assert(#vim.fn.getqflist() == 0, 'pick with no comments must not open quickfix')
mg.open_review()
assert(reset_warnings() == 1, 'review buffer with no notes must warn')

-- 1e. add_comment with cancelled (empty) input: no extmark, no side effects
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.ui.input = function(opts, cb) cb('') end
mg.add_comment()
assert(#vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}) == 0,
  'cancelled input must not create an extmark')

-- ===========================================================================
-- PHASE 2: happy paths
-- ===========================================================================
local STORE = DATA .. '/store1.json'
mg.setup { persist = true, json_path = STORE } -- default keymaps on
assert(vim.fn.maparg('<leader>Ra', 'n') ~= '', 'add map')
assert(vim.fn.maparg('<leader>Re', 'n') ~= '', 'edit map')
assert(vim.fn.maparg('<leader>Rc', 'n') ~= '', 'clear map')
assert(vim.fn.maparg('<leader>Rx', 'n') ~= '', 'export map')
assert(vim.fn.maparg('<leader>Rp', 'n') ~= '', 'pick map')
assert(vim.fn.maparg('<leader>Rt', 'n') ~= '', 'toggle map')
assert(vim.fn.maparg('<leader>Rv', 'n') ~= '', 'preview map')
assert(vim.fn.maparg(']R', 'n') ~= '', 'next map')
assert(vim.fn.maparg('[R', 'n') ~= '', 'prev map')

-- 2a. single-line comment on L2: full extmark anatomy
vim.ui.input = function(opts, cb) cb('fix this') end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
mg.add_comment()
local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
assert(#marks == 1, 'one comment expected, got ' .. #marks)
local m = marks[1]
assert(m[2] == 1, 'anchored to row 1 (line 2), got row ' .. m[2])
assert(m[4].virt_lines and #m[4].virt_lines == 1, 'virt_lines rows: ' .. #(m[4].virt_lines or {}))
assert(m[4].virt_lines[1][1][1]:find('⚑', 1, true), 'sign glyph in virt line')
assert(m[4].virt_lines[1][1][2] == 'MarginaliaSign', 'sign hl on the glyph chunk')
assert(m[4].virt_lines[1][2][1]:find('[L2]', 1, true), 'header contains [L2]: '
  .. tostring(m[4].virt_lines[1][2][1]))
assert(m[4].virt_lines[1][2][2] == 'MarginaliaBanner', 'banner hl in virt line')
assert(m[4].virt_lines_above == false,
  'comment text renders BELOW its line (virt_lines_above == false)')
assert(m[4].sign_text ~= nil and m[4].sign_text ~= '', 'sign_text present')
assert(m[4].sign_hl_group == 'MarginaliaSign', 'sign_hl_group')

-- 2b. multiline comment on L4: one virt row per text line
vim.ui.input = function(opts, cb) cb('multi\nline note') end
vim.api.nvim_win_set_cursor(0, { 4, 0 })
mg.add_comment()
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
assert(#marks == 2, 'two comments expected, got ' .. #marks)
local multi = marks[2]
assert(multi[2] == 3, 'second comment anchored to row 3 (line 4), got ' .. multi[2])
assert(#multi[4].virt_lines == 2, 'multiline -> 2 virt rows, got ' .. #multi[4].virt_lines)

-- 2c. visual range over lines 3..5
vim.ui.input = function(opts, cb) cb('range note') end
vim.cmd('normal! 3GV2j')
mg.add_comment()
local all = mg.get_all_comments()
local range_c
for _, c in ipairs(all) do
  if c.text == 'range note' then range_c = c end
end
assert(range_c ~= nil, 'range comment collected')
assert(range_c.line == 3 and range_c.end_line == 5,
  ('range must be L3-L5, got L%d-L%d'):format(range_c.line, range_c.end_line))

-- 2d. export text: entries + multiline joined, no code/context
vim.fn.setreg('+', '') -- the OS clipboard is shared across runs: start clean
mg.export_to_clipboard()
local rel = vim.fn.fnamemodify(path, ':~:.') -- the plugin's relpath rule
local reg = vim.fn.getreg('+')
assert(reg == rel .. ':2 fix this\n' .. rel .. ':3-5 range note\n'
  .. rel .. ':4 multi line note',
  'export matches the documented format exactly, got:\n' .. reg)
assert(not reg:find('  > ', 1, true), 'no code without include_code/context')
assert(not reg:find('  ~ ', 1, true), 'no context without context_lines')

-- 2e. include_code = true
mg.setup { persist = true, json_path = STORE, include_code = true }
vim.fn.setreg('+', '')
mg.export_to_clipboard()
reg = vim.fn.getreg('+')
assert(reg:find('  > local b = 2', 1, true), 'code line of L2: ' .. reg)
assert(reg:find('  > local d = 4', 1, true), 'code line of L4: ' .. reg)

-- 2f. context_lines = 1
mg.setup { persist = true, json_path = STORE, context_lines = 1 }
vim.fn.setreg('+', '')
mg.export_to_clipboard()
reg = vim.fn.getreg('+')
assert(reg:find('  ~ local a = 1', 1, true), 'context before L2: ' .. reg)
assert(reg:find('  ~ local c = 3', 1, true), 'context after L2: ' .. reg)

-- 2g. the debounced write lands on its own (no flush_store) before any
-- setup() switches json_path away — this also drains the pending timer so
-- later phases observe only their own schedules
local drained = vim.wait(2000, function()
  local raw = read_raw(STORE)
  return raw ~= nil and raw:find('range note', 1, true) ~= nil
end, 25)
assert(drained, 'the debounced write lands on disk without flush_store')

-- ===========================================================================
-- PHASE 3: store schema, atomicity, foreign shapes, EOF clamp, write errors.
-- NOTE: the production default json_path (stdpath('data')/marginalia.json)
-- is deliberately never touched — every store lives under DATA.
-- ===========================================================================
mg.setup { persist = true, json_path = STORE, context_lines = 0 }
mg.get_all_comments() -- heal the store from live extmarks after the reload
mg.flush_store()
local decoded = read_store(STORE)
assert(decoded ~= nil, 'store file written after flush')
assert(decoded.version == 1, 'version field: ' .. tostring(decoded.version))
assert(type(decoded.files) == 'table' and decoded.files[path] ~= nil,
  'files contains the path key')
assert(type(decoded.files[path][1]) == 'table', 'entries are tables (a real map)')
assert(#decoded.files[path] == 3, '3 entries stored, got ' .. #(decoded.files[path] or {}))
local anchor_checked
for _, e in ipairs(decoded.files[path]) do
  if e.text == 'fix this' then anchor_checked = e end
end
assert(anchor_checked ~= nil, 'L2 entry stored')
assert(anchor_checked.anchor == 'local b = 2', 'anchor is the commented line')
assert(anchor_checked.line == 2 and anchor_checked.end_line == 2, 'range stored')
assert(raw_empty and read_raw(STORE):find('"ts"', 1, true) == nil,
  'ts field dropped from the store schema')
assert(io.open(STORE .. '.tmp', 'r') == nil, 'atomic write leaves no tmp file')

-- 3a. foreign store shapes are ignored, never crash, never inject comments
-- (the collection is captured before and must be IDENTICAL after: any
-- injected comment — under any name — fails this)
local foreign_shapes = {
  ['array_empty.json'] = '[]',
  ['array_items.json'] = '[{"line":1,"text":"orphan note"}]',
  ['flat_map.json'] = '{"/tmp/opencode/mg_data/other.lua":[{"line":3,"text":"old note"}]}',
  -- infected notes live at IN-PROJECT absolute paths so a wrongly accepted
  -- shape would surface in the (project-scoped) collection and be caught
  ['wrong_version.json'] =
    '{"version":2,"files":{"' .. DATA .. '/future_file.lua":[{"line":1,"text":"future note"}]}}',
  ['missing_version.json'] =
    '{"files":{"' .. DATA .. '/no_version_file.lua":[{"line":1,"text":"no version note"}]}}',
  ['corrupt2.json'] = '{"version": 1, "files":',
}
local pre_uids = {}
for _, c in ipairs(mg.get_all_comments()) do
  pre_uids[#pre_uids + 1] = c.uid
end
for fname, content in pairs(foreign_shapes) do
  local fpath = DATA .. '/' .. fname
  write_file(fpath, content)
  local okf, errf = pcall(mg.setup, { persist = true, json_path = fpath })
  assert(okf, 'foreign shape "' .. fname .. '" loads without crash: ' .. tostring(errf))
  local post_uids = {}
  for _, c in ipairs(mg.get_all_comments()) do
    post_uids[#post_uids + 1] = c.uid
    assert(c.text ~= 'orphan note' and c.text ~= 'old note'
      and c.text ~= 'future note' and c.text ~= 'no version note',
      'foreign shape "' .. fname .. '" must not inject comments')
  end
  table.sort(pre_uids)
  table.sort(post_uids)
  assert(#pre_uids == #post_uids, 'foreign shape "' .. fname .. '" changed the collection size')
  for j = 1, #pre_uids do
    assert(pre_uids[j] == post_uids[j], 'foreign shape "' .. fname
      .. '" changed the collection')
  end
  os.remove(fpath)
end

-- 3b. unreadable-but-existing store is preserved byte-for-byte before any
-- later write can replace it
local CORRUPT = '{"version": 1, "files": {"oops'
write_file(STORE, CORRUPT)
mg.setup { persist = true, json_path = STORE }
assert(read_raw(STORE .. '.unreadable') == CORRUPT,
  'unreadable store preserved as .unreadable (byte-exact)')
mg.get_all_comments() -- store is empty now; heal brings the live notes back
mg.flush_store()
assert(read_raw(STORE .. '.unreadable') == CORRUPT,
  '.unreadable survives the first successful write')
decoded = read_store(STORE)
assert(decoded.version == 1 and decoded.files[path] ~= nil,
  'the store recovers to a valid format after a failed load')

-- 3c. store write failures surface as errors, not silence.
-- json_path inside a nonexistent directory -> writefile itself fails.
mg.setup { persist = true, json_path = DATA .. '/no_such_dir/store.json' }
vim.ui.input = function(opts, cb) cb('write failure note') end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
mg.add_comment()
reset_errors()
mg.flush_store()
assert(reset_errors() == 1, 'failed store write must notify an error')

-- 3c1. a directory-shaped json_path must never be renamed or replaced:
-- the write fails with an error and the directory survives untouched
vim.fn.mkdir(DATA .. '/as_dir', 'p')
mg.setup { persist = true, json_path = DATA .. '/as_dir' }
vim.ui.input = function(opts, cb) cb('dir victim') end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
mg.add_comment()
reset_errors()
mg.flush_store()
assert(reset_errors() == 1, 'directory-shaped json_path must notify an error')
assert(vim.fn.isdirectory(DATA .. '/as_dir') == 1,
  'the directory must survive a failed store write untouched')

-- 3c2. merge edge cases at LOAD time: uid == 0 reassigned, end_line < line
-- clamped (pure store semantics — restore clamping is 3d's job)
local path_edge = DATA .. '/edge.lua'
write_file(path_edge, 'e1\ne2\n')
write_file(DATA .. '/store_edge.json',
  ('{"version":1,"files":{"%s":[{"line":5,"end_line":2,"text":"edge note","uid":0}]}}'):format(path_edge))
mg.setup { persist = true, json_path = DATA .. '/store_edge.json' }
local edge_entry
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == path_edge then edge_entry = c end
end
assert(edge_entry ~= nil, 'edge-case store entry loaded')
assert(edge_entry.line == 5 and edge_entry.end_line == 5,
  'end_line < line clamped to line at load, got L' .. edge_entry.line .. '-L' .. edge_entry.end_line)
assert(edge_entry.uid > 0, 'uid 0 reassigned to a fresh positive uid')

-- 3d. restore clamps a line beyond EOF to the last line — with an anchor:
-- the clamped fallback must NOT overwrite the stored anchor (the anchor can
-- still match after further edits)
local clamp_path = DATA .. '/clamp_demo.lua'
write_file(clamp_path, 'x\ny\nz\n')
write_file(DATA .. '/store_clamp.json',
  ('{"version":1,"files":{"%s":[{"line":9,"text":"beyond eof","end_line":9,"anchor":"gamma","uid":55}]}}'):format(clamp_path))
mg.setup { persist = true, json_path = DATA .. '/store_clamp.json' }
vim.cmd('edit ' .. vim.fn.fnameescape(clamp_path))
local buf3 = vim.api.nvim_get_current_buf()
marks = vim.api.nvim_buf_get_extmarks(buf3, ns, 0, -1, { details = true })
assert(#marks == 1, 'clamp: comment restored, got ' .. #marks)
assert(marks[1][2] == 2, 'clamp: line 9 -> last line 3 (row 2), got row ' .. marks[1][2])
-- the extmark row alone can't fail (the API errors on out-of-range rows);
-- the PLUGIN-side clamp is proven by the store sync-back after a flush
mg.flush_store()
local clamp_entry
for _, e in ipairs(read_store(DATA .. '/store_clamp.json').files[clamp_path]) do
  if e.text == 'beyond eof' then clamp_entry = e end
end
assert(clamp_entry ~= nil and clamp_entry.line == 3,
  'clamp: store entry synced to the clamped line, got ' .. tostring(clamp_entry and clamp_entry.line))
assert(clamp_entry.anchor == 'gamma',
  'clamp+fallback must not overwrite the stored anchor, got '
    .. tostring(clamp_entry.anchor))
vim.cmd('bdelete!')

-- ===========================================================================
-- PHASE 4: toggle / preview / edit / clear / delete (STORE state again)
-- ===========================================================================
mg.setup { persist = true, json_path = STORE }
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
assert(#marks == 3, 're-setup must not duplicate extmarks, got ' .. #marks)

-- 4a. hide all, then add a fresh note while hidden; navigation must SKIP
-- the hidden ones (not merely find nothing navigable)
local orig_uids = {}
for _, mm in ipairs(marks) do
  orig_uids[#orig_uids + 1] = mm[1]
end
mg.toggle_comments()
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
for _, mm in ipairs(marks) do
  if contains(orig_uids, mm[1]) then
    assert(#(mm[4].virt_lines or {}) == 0, 'virt_lines blanked when hidden')
    local st = mm[4].sign_text
    assert(st == '' or st == nil, 'sign cleared when hidden, got ' .. tostring(st))
  end
end
-- the range note's marks (tint + text in range_ns) are gone too when hidden
assert(#range_extmarks(bufnr) == 0, 'range markers blanked when hidden')
assert(#mg.get_all_comments() == 3, 'hidden comments still collected')
mg.export_to_clipboard()
assert(vim.fn.getreg('+'):find('demo%.lua:2'), 'hidden comments still exported')
-- a note added while hidden is visible immediately
vim.ui.input = function(opts, cb) cb('added while hidden') end
vim.api.nvim_win_set_cursor(0, { 5, 0 })
mg.add_comment()
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
local fresh_note
for _, mm in ipairs(marks) do
  if not contains(orig_uids, mm[1]) then fresh_note = mm end
end
assert(fresh_note ~= nil and fresh_note[2] == 4, 'the hidden-time note anchors to L5')
assert(#(fresh_note[4].virt_lines or {}) > 0, 'a note added while hidden is visible')
-- navigation from L1 must land on L5 (visible), skipping hidden L2/L3/L4
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.next_comment()
assert(vim.fn.line '.' == 5, 'next skips hidden comments and lands on L5, got '
  .. vim.fn.line('.'))

-- 4b. toggle show: everything restored. The L3-5 range note's TEXT lives in
-- range_ns below the range END (review-thread convention); its comment
-- extmark carries only the sign. Single-line notes carry virt_lines as before.
mg.toggle_comments()
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
local range_uids = {}
for _, c in ipairs(mg.get_all_comments()) do
  if c.end_line > c.line then range_uids[c.uid] = true end
end
for _, mm in ipairs(marks) do
  assert(mm[4].sign_hl_group == 'MarginaliaSign', 'sign restored on show')
  if not range_uids[mm[1]] then
    assert(#(mm[4].virt_lines or {}) > 0, 'virt_lines restored on show')
  end
end
-- the range note's text extmark sits at row 4 (below L5, the range END)
local rn_shown = vim.api.nvim_buf_get_extmarks(bufnr, range_ns, 0, -1, { details = true })
local rn_text
for _, rn in ipairs(rn_shown) do
  if rn[4].virt_lines and #rn[4].virt_lines > 0 then rn_text = rn end
end
assert(rn_text ~= nil and rn_text[2] == 4,
  'range text hangs below the range END (row 4 = below L5), got row '
    .. tostring(rn_text and rn_text[2]))
local rn_text_det = rn_text and vim.api.nvim_buf_get_extmark_by_id(bufnr, range_ns,
  rn_text[1], { details = true })
assert(rn_text_det ~= nil and rn_text_det[3].virt_lines_above == false,
  'range text renders BELOW the range end')
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.next_comment()
assert(vim.fn.line '.' == 2, 'next works again after show, got ' .. vim.fn.line('.'))

-- 4c. floating preview: geometry, content, dismiss
vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- multiline comment (fits above)
mg.preview_comment()
local floats = float_windows()
assert(#floats == 1, 'preview window open, got ' .. #floats)
local pconfig = vim.api.nvim_win_get_config(floats[1])
-- "above the cursor" in absolute screen rows: the float's bottom edge
-- (anchor='SW' -> win_screenpos returns the bottom-left corner) must be
-- strictly above the cursor's screen line. winline() already accounts for
-- the virt_lines rows above the cursor line.
local base = vim.fn.win_screenpos(0)
local cursor_abs = base[1] + vim.fn.winline() - 1
local fpos = vim.fn.win_screenpos(floats[1])
assert(fpos[1] < cursor_abs, 'preview floats above the cursor line: '
  .. fpos[1] .. ' !< ' .. cursor_abs)
assert(pconfig.relative ~= '', 'preview is a floating window')
assert(pconfig.anchor == 'SW', 'preview anchored bottom-above: ' .. tostring(pconfig.anchor))
assert(pconfig.width >= 20, 'preview width clamp (>= 20), got ' .. tostring(pconfig.width))
local plines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(floats[1]), 0, -1, false)
assert(plines[1]:find('demo%.lua:4'), 'preview header shows path:line: ' .. tostring(plines[1]))
assert(plines[3] == 'multi' and plines[4] == 'line note', 'preview body shows comment text')
vim.cmd('doautocmd CursorMoved')
assert(#float_windows() == 0, 'preview closed on CursorMoved')

-- 4c2. 30-line note: inline rendering shows all rows, preview clamps to 20
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.ui.input = function(opts, cb)
  local big = {}
  for i = 1, 30 do big[i] = 'big line ' .. i end
  cb(table.concat(big, '\n'))
end
mg.add_comment()
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
local big_mark
for _, mm in ipairs(marks) do
  if mm[2] == 0 then big_mark = mm end
end
assert(big_mark ~= nil, '30-line note added on L1')
assert(#big_mark[4].virt_lines == 30, 'inline rendering shows all 30 rows, got '
  .. #big_mark[4].virt_lines)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.preview_comment()
local big_float = float_windows()[1]
assert(big_float ~= nil, 'preview for the 30-line note opened')
-- the cap is module-side: the float BUFFER must hold exactly 20 lines
local big_buf = vim.api.nvim_win_get_buf(big_float)
assert(vim.api.nvim_buf_line_count(big_buf) == 20,
  'preview content clamped to 20 lines, got ' .. vim.api.nvim_buf_line_count(big_buf))
vim.cmd('doautocmd CursorMoved')
assert(#float_windows() == 0, '30-line preview closed')

-- 4d. edit_comment rewrites payload + store
local real_input = vim.fn.input
vim.fn.input = function(o) return 'edited note' end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
mg.edit_comment()
vim.fn.input = real_input
local edited
for _, c in ipairs(mg.get_all_comments()) do
  if c.text == 'edited note' then edited = c end
end
assert(edited ~= nil and edited.line == 2, 'edit_comment rewrote payload in place')
mg.flush_store()
local found_in_store = false
for _, e in ipairs(read_store(STORE).files[path]) do
  if e.text == 'edited note' then found_in_store = true end
end
assert(found_in_store, 'edited text persisted')

-- 4d2. cancel leaves the note untouched
vim.fn.input = function(o) return '\27' end
mg.edit_comment()
vim.fn.input = real_input
local still_there
for _, c in ipairs(mg.get_all_comments()) do
  if c.text == 'edited note' then still_there = c end
end
assert(still_there ~= nil, 'cancelled edit must not change the note text')

-- 4d3. interrupted edit (<C-c>) does not crash and keeps the note
vim.fn.input = function(o) error('Interrupted') end
mg.edit_comment()
vim.fn.input = real_input
local survived
for _, c in ipairs(mg.get_all_comments()) do
  if c.text == 'edited note' then survived = c end
end
assert(survived ~= nil, 'interrupted edit must not crash and keep the note')

-- 4d4. editing a multiline note keeps its range (end_line)
local multi_line_c
for _, c in ipairs(mg.get_all_comments()) do
  if c.text == 'multi\nline note' then multi_line_c = c end
end
assert(multi_line_c ~= nil and multi_line_c.end_line == 4, 'multiline note pre-state')
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.fn.input = function(o) return 'multi\nline note v2' end
mg.edit_comment()
vim.fn.input = real_input
local v2_found = false
for _, c in ipairs(mg.get_all_comments()) do
  if c.text:find('v2', 1, true) then
    v2_found = true
    assert(c.line == 4 and c.end_line == 4,
      'edit keeps the stored range, got L' .. c.line .. '-L' .. c.end_line)
  end
end
assert(v2_found, 'the multiline note was actually re-edited (v2 present)')

-- 4e. clear_current_comment removes extmark + store entry
-- (demo has 4 comments at this point: L1 big, L2 edited, L3-5 range, L4 v2)
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- range comment anchor
mg.clear_current_comment()
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
assert(#marks == 4, 'one comment removed (5 -> 4), got ' .. #marks)
mg.flush_store()
local entries = read_store(STORE).files[path]
assert(#entries == 4, 'store entry removed, got ' .. #entries)
for _, e in ipairs(entries) do
  assert(e.text ~= 'range note', 'cleared entry gone from store')
end

-- 4f. M.delete_comment API (the unit backing the picker "d" action)
all = mg.get_all_comments()
mg.delete_comment(all[1]) -- sorted first = L1 big note
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
assert(#marks == 3, 'delete_comment removed extmark (4 -> 3), got ' .. #marks)
mg.flush_store()
entries = read_store(STORE).files[path]
assert(#entries == 3, 'delete_comment removed store entry, got ' .. #entries)

-- ===========================================================================
-- PHASE 5: anchor relocation on restore + unloaded-buffer collection
-- ===========================================================================
local path2 = DATA .. '/demo2.lua'
write_file(path2, 'alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n')
vim.cmd('edit ' .. vim.fn.fnameescape(path2))
local buf2 = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb('anchor me') end
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- 'gamma'
mg.add_comment()
local demo2_entry
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == path2 then demo2_entry = c end
end
assert(demo2_entry ~= nil and demo2_entry.text == 'anchor me', 'comment added to demo2')
assert(demo2_entry.line == 3, 'demo2 comment at L3')
mg.flush_store()

-- session A -> B: file edited on disk (line inserted on top, gamma now L4);
-- the comment moves via anchor search, not via the stale line number
write_file(path2, 'zero\nalpha\nbeta\ngamma\ndelta\nepsilon\n')
vim.cmd('bdelete!')
vim.cmd('edit ' .. vim.fn.fnameescape(path2))
buf2 = vim.api.nvim_get_current_buf()
marks = vim.api.nvim_buf_get_extmarks(buf2, ns, 0, -1, { details = true })
assert(#marks == 1, 'comment restored after reload, got ' .. #marks)
assert(marks[1][2] == 3, 'anchor search moved comment to L4 (row 3), got row ' .. marks[1][2])
mg.flush_store()

-- anchor text gone entirely: restore falls back to the stored line (L4)
-- and must NOT overwrite the original anchor with the fallback line's text
write_file(path2, 'one\ntwo\nthree\nfour\nfive\nsix\n')
vim.cmd('bdelete!')
vim.cmd('edit ' .. vim.fn.fnameescape(path2))
buf2 = vim.api.nvim_get_current_buf()
marks = vim.api.nvim_buf_get_extmarks(buf2, ns, 0, -1, { details = true })
assert(#marks == 1, 'fallback restore after content rewrite, got ' .. #marks)
assert(marks[1][2] == 3, 'fallback keeps stored line (row 3), got row ' .. marks[1][2])
mg.flush_store()
local fallback_entry
for _, e in ipairs(read_store(STORE).files[path2] or {}) do
  if e.text == 'anchor me' then fallback_entry = e end
end
assert(fallback_entry ~= nil, 'fallback entry present in store')
assert(fallback_entry.anchor == 'gamma',
  'fallback restore must NOT overwrite the original anchor, got '
    .. tostring(fallback_entry.anchor))

-- unloaded buffer: collection comes from the store
vim.cmd('bdelete! ' .. buf2)
local from_store
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == path2 then from_store = c end
end
assert(from_store ~= nil, 'unloaded buffer comment collected from store')
assert(from_store.bufnr == nil, 'unloaded entry has no live bufnr')
assert(from_store.line == 4, 'store synced to anchor-adjusted line, got ' .. from_store.line)

-- export from an unloaded file exercises the readfile branch
mg.export_to_clipboard()
reg = vim.fn.getreg('+')
assert(reg:find('demo2%.lua:4 anchor me'), 'unloaded file export: ' .. reg)

-- 5b. include_code from an unloaded file: code comes from disk, not a buffer
mg.setup { persist = true, json_path = STORE, include_code = true }
mg.export_to_clipboard()
reg = vim.fn.getreg('+')
assert(reg:find('demo2%.lua:4 anchor me'), 'unloaded anchor entry: ' .. reg)
assert(reg:find('  > four', 1, true), 'unloaded file code line (readfile): ' .. reg)
mg.setup { persist = true, json_path = STORE, include_code = false }

-- 5c. quickfix fallback WITH comments: telescope is absent in this headless
-- run, so pick_comments must open a titled quickfix with the right item
vim.cmd('edit ' .. vim.fn.fnameescape(path2))
local buf2b = vim.api.nvim_get_current_buf()
vim.fn.setqflist({}, 'r')
reset_warnings()
mg.pick_comments()
assert(reset_warnings() == 1, 'missing telescope must warn')
assert(vim.fn.getqflist({ title = 0 }).title == 'Marginalia: review comments',
  'quickfix title set, got: ' .. tostring(vim.fn.getqflist({ title = 0 }).title))
local qf_items = vim.fn.getqflist()
assert(#qf_items > 0, 'quickfix holds the comments')
local qf_demo2
for _, item in ipairs(qf_items) do
  if item.bufnr == buf2b and item.lnum == 4 then qf_demo2 = item end
end
assert(qf_demo2 ~= nil, 'quickfix item points at demo2.lua:4')

-- 5d. hidden state survives a buffer reload (hide -> setup restore)
vim.cmd('cclose') -- the quickfix from 5c is the active window; leave it
vim.cmd('edit ' .. vim.fn.fnameescape(path2)) -- current buffer = demo2
mg.toggle_comments() -- hide demo2's note
local demo2_marks = vim.api.nvim_buf_get_extmarks(buf2b, ns, 0, -1, { details = true })
for _, mm in ipairs(demo2_marks) do
  local st = mm[4].sign_text
  assert(st == '' or st == nil, 'demo2 note hidden before the reload')
end
mg.setup { persist = true, json_path = STORE } -- setup re-restores loaded buffers
local demo2_marks2 = vim.api.nvim_buf_get_extmarks(buf2b, ns, 0, -1, { details = true })
assert(#demo2_marks2 == 1, 'demo2 note restored after the reload, got ' .. #demo2_marks2)
local st2 = demo2_marks2[1][4].sign_text
assert(st2 == '' or st2 == nil, 'restored note stays hidden across the reload')
mg.toggle_comments() -- show again for the remaining phases

-- 5e. export with a store entry whose file no longer exists: no crash
write_file(DATA .. '/store_ghost.json',
  ('{"version":1,"files":{"%s":[{"line":1,"text":"ghost note","end_line":1,"uid":66}]}}')
    :format(DATA .. '/ghost_file_that_does_not_exist.lua'))
mg.setup { persist = true, json_path = DATA .. '/store_ghost.json' }
mg.export_to_clipboard()
reg = vim.fn.getreg('+')
assert(reg:find('ghost_file_that_does_not_exist%.lua:1 ghost'),
  'export includes comments from deleted files (readfile failure tolerated): ' .. reg)
-- back to the main store for the remaining phases
mg.setup { persist = true, json_path = STORE }

-- ===========================================================================
-- PHASE 6: collection ordering + duplicate refusal + wraps + store-only delete
-- ===========================================================================

-- 6a. collection is sorted by path, then line (demo.lua before demo2.lua)
all = mg.get_all_comments()
assert(all[1].abspath == path, 'collection sorted by path (demo.lua first)')
for i = 2, #all do
  if all[i].abspath == all[i - 1].abspath then
    assert(all[i].line >= all[i - 1].line, 'collection sorted by line within a path')
  end
end

-- 6b. one note per anchor line: a second add on an anchored line is refused
-- (edit/clear/preview address the single comment anchored to a line)
vim.cmd('edit ' .. vim.fn.fnameescape(path))
vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- the 'added while hidden' note's line
reset_warnings()
vim.ui.input = function(opts, cb) cb('duplicate attempt') end
mg.add_comment()
assert(reset_warnings() == 1, 'duplicate note on an anchored line must warn')
local duplicates = 0
for _, c in ipairs(mg.get_all_comments()) do
  if c.text == 'duplicate attempt' then duplicates = duplicates + 1 end
end
assert(duplicates == 0, 'duplicate note must not be created')

-- 6c. wraps: prev from the first comment line wraps to the last one,
-- next from the last wraps back to the first
marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
local first_line, last_line = math.huge, 0
for _, mm in ipairs(marks) do
  first_line = math.min(first_line, mm[2] + 1)
  last_line = math.max(last_line, mm[2] + 1)
end
vim.api.nvim_win_set_cursor(0, { first_line, 0 })
mg.prev_comment()
assert(vim.fn.line '.' == last_line, 'prev wraps from first to last comment line, got '
  .. vim.fn.line('.') .. ', expected ' .. last_line)
mg.next_comment()
assert(vim.fn.line '.' == first_line, 'next wraps from last to first comment line, got '
  .. vim.fn.line('.') .. ', expected ' .. first_line)

-- 6d. delete_comment on a store-only (unloaded) comment; the hidden/
-- comment_data cleanup here is load-bearing: the live extmark is already
-- gone, but session payload state may still exist for the uid.
vim.cmd('bdelete! ' .. buf2b) -- unload demo2
local store_only
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == path2 then store_only = c end
end
assert(store_only ~= nil and store_only.bufnr == nil, 'precondition: store-only comment')
mg.delete_comment(store_only)
local gone = true
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == path2 then gone = false end
end
assert(gone, 'store-only comment removed by delete_comment')
mg.flush_store()
assert(read_store(STORE).files[path2] == nil, 'store-only deletion persisted')

-- ===========================================================================
-- PHASE 7: colorscheme switch keeps the highlight groups alive
-- ===========================================================================
local ok_cs = pcall(vim.cmd, 'colorscheme default')
if not ok_cs then ok_cs = pcall(vim.cmd, 'colorscheme blue') end
if ok_cs then
  local hl = vim.api.nvim_get_hl(0, { name = 'MarginaliaBanner' })
  assert(type(hl) == 'table' and hl.bg ~= nil,
    'MarginaliaBanner survives a colorscheme switch (ColorScheme autocmd)')
  local hl2 = vim.api.nvim_get_hl(0, { name = 'MarginaliaSign' })
  assert(type(hl2) == 'table' and hl2.fg ~= nil,
    'MarginaliaSign survives a colorscheme switch')
else
  print('WARNING: no builtin colorscheme available — colorscheme test skipped')
end

-- ===========================================================================
-- PHASE 8: sign_text / preview border / selective keymaps / re-setup unmapping
-- ===========================================================================
mg.setup {
  persist = true, json_path = STORE,
  sign_text = '◆',
  preview = { border = 'double' },
  keymaps = { add = '<leader>Z', edit = false },
}
assert(vim.fn.maparg('<leader>Z', 'n') ~= '', 'custom add map registered')
assert(vim.fn.maparg('<leader>Ra', 'n') == '', 'replaced default add map is unmapped')
assert(vim.fn.maparg('<leader>Re', 'n') == '', 'keymaps.edit=false disables edit')
-- merge semantics: unspecified keys keep their defaults
assert(vim.fn.maparg('<leader>Rc', 'n') ~= '', 'unspecified keymaps keep defaults')

marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
local custom_sign_seen = false
for _, mm in ipairs(marks) do
  local st = mm[4].sign_text
  -- nvim pads single-cell signs to two cells
  if st and st:find('◆', 1, true) then custom_sign_seen = true end
end
assert(custom_sign_seen, 'custom sign_text is used by the renderer')

vim.api.nvim_win_set_cursor(0, { 2, 0 })
mg.preview_comment()
local cf = float_windows()[1]
assert(cf ~= nil, 'custom-config preview opened')
local border = vim.api.nvim_win_get_config(cf).border
-- the plugin's contract is FORWARDING cfg.preview.border; nvim may expand
-- a named border into its 8-piece table, so accept both shapes
assert(border == 'double' or (type(border) == 'table' and border[1] == '╔'),
  'custom preview border applied, got ' .. vim.inspect(border))
vim.cmd('doautocmd CursorMoved')
assert(#float_windows() == 0, 'custom-config preview closed')

-- ===========================================================================
-- PHASE 9: on_hover preview + the debounce itself + persist=false no-load
-- ===========================================================================
mg.setup { persist = true, json_path = STORE, preview = { on_hover = true } }
vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- 'edited note' line
vim.cmd('doautocmd CursorHold')
assert(#float_windows() == 1, 'on_hover opens the preview on a commented line')
vim.cmd('doautocmd CursorMoved') -- dismisses via the once-autocmd
vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- no comment on L3
vim.cmd('doautocmd CursorHold')
assert(#float_windows() == 0, 'on_hover shows nothing on comment-less lines')

mg.setup { persist = true, json_path = DATA .. '/debounced.json' }
write_file(DATA .. '/debounced_target.lua', 'a\nb\nc\n')
vim.cmd('edit ' .. vim.fn.fnameescape(DATA .. '/debounced_target.lua'))
vim.ui.input = function(opts, cb) cb('debounced note') end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
mg.add_comment() -- schedules the 300ms write; nothing calls flush_store
local debounced_ok = vim.wait(2000, function()
  local raw = read_raw(DATA .. '/debounced.json')
  return raw ~= nil and raw:find('debounced note', 1, true) ~= nil
end, 25)
assert(debounced_ok, 'the debounced write lands on disk without flush_store')

-- persist=false vs persist=true on the same populated store file: false
-- must ignore it (no cross-session load), true must load it
vim.cmd('bdelete!') -- unload the debounced buffer: its notes would come from the store
local target = DATA .. '/debounced_target.lua'
mg.setup { persist = false, json_path = DATA .. '/debounced.json' }
local loaded_with_false = false
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == target then loaded_with_false = true end
end
assert(not loaded_with_false, 'persist=false loads no cross-session state')
mg.setup { persist = true, json_path = DATA .. '/debounced.json' }
local loaded_with_true = false
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == target then loaded_with_true = true end
end
assert(loaded_with_true, 'persist=true loads cross-session state')

-- ===========================================================================
-- PHASE 10: text robustness — Unicode (CJK, emoji, combining marks, RTL),
-- extreme lengths. Invariants to pin: JSON store round-trip is byte-exact
-- for arbitrary text; virt_lines rows == text lines regardless of content;
-- preview/export/navigation never crash on any of it. NOT tested: pixel
-- width of glyphs (nvim's strdisplaywidth domain).
-- ===========================================================================
mg.setup { persist = true, json_path = STORE }
local uni = DATA .. '/unicode.lua'
write_file(uni, 'ascii\n中文注释\nemoji 🚀🔥🎨\ncombining áé\nrtl مر حبا\nlong ' ..
  string.rep('я', 5000) .. '\n')
vim.cmd('edit ' .. vim.fn.fnameescape(uni))
local ub = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb)
  cb('примечание ✓ 日本語 🎌 — 中文 — 🚀')
end
vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- '中文注释'
mg.add_comment()
marks = vim.api.nvim_buf_get_extmarks(ub, ns, 0, -1, { details = true })
assert(#marks == 1, 'unicode note added, got ' .. #marks)
assert(#marks[1][4].virt_lines == 1, 'one text line -> one virt row regardless of glyph width')
assert(marks[1][4].virt_lines[1][2][1]:find('日本語', 1, true),
  'CJK survives into the virt line')
mg.flush_store()
local uni_entry
for _, e in ipairs(read_store(STORE).files[uni]) do
  if e.text:find('примечание', 1, true) then uni_entry = e end
end
assert(uni_entry ~= nil and uni_entry.text == 'примечание ✓ 日本語 🎌 — 中文 — 🚀',
  'CJK/emoji comment survives the JSON round-trip byte-exact, got: '
    .. tostring(uni_entry and uni_entry.text))
-- extreme lengths: 200-line note (inline rows uncapped) + 10k-char single line
vim.ui.input = function(opts, cb)
  local many = {}
  for i = 1, 200 do many[i] = 'строка ' .. i end
  cb(table.concat(many, '\n'))
end
vim.api.nvim_win_set_cursor(0, { 3, 0 })
mg.add_comment()
marks = vim.api.nvim_buf_get_extmarks(ub, ns, 0, -1, { details = true })
local long_note
for _, mm in ipairs(marks) do
  if mm[2] == 2 then long_note = mm end
end
assert(long_note ~= nil and #long_note[4].virt_lines == 200,
  'a 200-line note renders 200 virt rows, got ' .. #(long_note[4].virt_lines or {}))
vim.ui.input = function(opts, cb)
  cb(string.rep('𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ', 1000)) -- ~10k chars, astral-plane per word
end
vim.api.nvim_win_set_cursor(0, { 5, 0 })
mg.add_comment()
all = mg.get_all_comments()
local astral
for _, c in ipairs(all) do
  if c.text:find('𝕌𝕟𝕚𝕔𝕠𝕕𝕖', 1, true) then astral = c end
end
assert(astral ~= nil and #astral.text > 9000, 'a ~10k astral-plane note round-trips')
-- restore through the whole pipeline: reload -> anchor -> text intact
mg.flush_store()
vim.cmd('bdelete!')
vim.cmd('edit ' .. vim.fn.fnameescape(uni))
marks = vim.api.nvim_buf_get_extmarks(vim.api.nvim_get_current_buf(), ns, 0, -1, {})
assert(#marks == 3, 'all unicode/length notes restored, got ' .. #marks)
mg.export_to_clipboard()
reg = vim.fn.getreg('+')
assert(reg:find('unicode%.lua:2 примечание ✓ 日本語'), 'export keeps CJK/emoji text: ' .. reg)

-- ===========================================================================
-- PHASE 11: clipboard provider detection (forced probes: machine-independent)
-- ===========================================================================
local real_exec = vim.fn['provider#clipboard#Executable']

-- 10a. provider present (stubbed) -> success notify, unnamed register
-- untouched (a user's yank must never be clobbered by an export)
vim.fn['provider#clipboard#Executable'] = function() return 'stub-exe' end
vim.g.clipboard = nil
mg.setup { persist = true, json_path = STORE, include_code = false }
vim.fn.setreg('+', '')
vim.fn.setreg('"', 'MY YANKED TEXT')
mg.export_to_clipboard()
assert(vim.fn.getreg('+') ~= 'MY YANKED TEXT', 'export writes "+"')
assert(vim.fn.getreg('"') == 'MY YANKED TEXT',
  'with a provider, the unnamed register must be left untouched')

-- 10b. a user-defined g:clipboard counts as a provider even when no tool is found
vim.fn['provider#clipboard#Executable'] = function() return '' end
vim.g.clipboard = { name = 'stub-provider', copy = {}, paste = {} }
vim.fn.setreg('"', 'MY YANKED TEXT')
mg.export_to_clipboard()
assert(vim.fn.getreg('"') == 'MY YANKED TEXT', 'g:clipboard counts as a provider')

-- 10c. no provider at all: warn + unnamed-register fallback
vim.g.clipboard = nil
vim.fn['provider#clipboard#Executable'] = function() return '' end
reset_warnings()
vim.fn.setreg('"', '')
mg.export_to_clipboard()
assert(reset_warnings() == 1, 'missing provider must warn')
assert(vim.fn.getreg('"'):find('demo.lua:2', 1, true),
  'without a provider the text lands in the unnamed register as a fallback')
vim.fn['provider#clipboard#Executable'] = real_exec
vim.g.clipboard = nil

-- ===========================================================================
-- PHASE 12: review buffer — all notes in one editable scratch buffer.
-- NO two-way sync: edits live only in the review copy; the canonical notes
-- stay in the store. The user tweaks text there, copies it, sends it away.
-- ===========================================================================
mg.open_review()
local rb = find_review_buf()
assert(rb ~= nil and vim.api.nvim_buf_is_valid(rb), 'review buffer created')
assert(vim.bo[rb].buftype == '', 'review buffer is a plain editable buffer')
local review_win
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_buf(w) == rb then review_win = w end
end
assert(review_win ~= nil, 'review buffer is displayed')

-- content: sections sorted by path then line (get_all_comments order), one
-- header per note, bodies inline, blank line between sections — the expected
-- rows are built here independently from the module's formatter
local expected = {}
for _, c in ipairs(mg.get_all_comments()) do
  expected[#expected + 1] = ('=== %s:%d%s ==='):format(c.relpath, c.line,
    c.end_line > c.line and ('-' .. c.end_line) or '')
  for _, l in ipairs(vim.split(c.text, '\n', { plain = true })) do
    expected[#expected + 1] = l
  end
  expected[#expected + 1] = ''
end
local got = vim.api.nvim_buf_get_lines(rb, 0, -1, false)
assert(#got == #expected, ('review buffer rows %d ~= expected %d'):format(#got, #expected))
for i = 1, #expected do
  assert(got[i] == expected[i], ('review row %d mismatch:\nexpected %q\ngot      %q')
    :format(i, expected[i], got[i]))
end

-- 12a. edits in the review buffer belong to the user: a re-open with
-- unsaved edits focuses the buffer and must NOT clobber them
vim.api.nvim_buf_set_lines(rb, 0, -1, false, { 'my edited line' })
assert(vim.bo[rb].modified, 'precondition: edited review buffer')
reset_warnings()
mg.open_review()
assert(reset_warnings() == 1, 're-open with unsaved edits must warn')
got = vim.api.nvim_buf_get_lines(rb, 0, -1, false)
assert(#got == 1 and got[1] == 'my edited line', 'the edited copy must survive re-open')

-- 12a2. the buffer-local copy key sends the EDITED content to "+":
-- full equality — the review copy is exactly what gets sent
vim.fn.setreg('+', '')
vim.api.nvim_buf_call(rb, function() mg.copy_review() end)
assert(vim.fn.getreg('+') == 'my edited line',
  'buffer-local copy sends the edited review content to "+"')

-- 12a3. the buffer-local keymaps carry which-key descriptions. which-key
-- renders the keymap `desc` field next to each key; with a nil desc the
-- popup shows the key with an EMPTY label (what "g" looked broken).
local rkmaps = vim.api.nvim_buf_get_keymap(rb, 'n')
local rdesc = {}
for _, mk in ipairs(rkmaps) do rdesc[mk.lhs] = mk.desc or '' end
assert(rdesc['gy'] ~= nil and rdesc['gy'] ~= '',
  'review gy keymap must carry a which-key desc, got: ' .. tostring(rdesc['gy']))
assert(rdesc['q'] ~= nil and rdesc['q'] ~= '',
  'review q keymap must carry a which-key desc, got: ' .. tostring(rdesc['q']))
assert(rdesc['<CR>'] ~= nil and rdesc['<CR>'] ~= '',
  'review <CR> keymap must carry a which-key desc, got: ' .. tostring(rdesc['<CR>']))

-- 12b. an unmodified re-open re-renders the canonical list
vim.bo[rb].modified = false
mg.open_review()
got = vim.api.nvim_buf_get_lines(rb, 0, -1, false)
assert(#got == #expected and got[#got] == expected[#expected],
  'an unmodified re-open re-renders the canonical list')
assert(vim.bo[rb].modified == false, 'the refreshed buffer is clean')

-- 12b2. the review buffer must not leak into get_all_comments
local n_before = #mg.get_all_comments()
mg.open_review() -- unmodified -> refresh
assert(#mg.get_all_comments() == n_before,
  'the review buffer must not appear in the notes collection')

-- 12c. close_review wipes the review buffer
mg.close_review()
assert(find_review_buf() == nil, 'close_review removes the review buffer')

-- 12d. a closed review buffer is recreated from the store on re-open
mg.open_review()
rb = find_review_buf()
assert(rb ~= nil and #vim.api.nvim_buf_get_lines(rb, 0, -1, false) == #expected,
  'a closed review buffer is recreated on open')
mg.close_review()

-- ===========================================================================
-- PHASE 13: comment placement below the line + range marker options
-- (range_marker = 'tint' (default) | 'signs' | 'both'). The tint is a
-- full-range highlight in the text area; 'signs' draws a '│' continuator in
-- the signcolumn at LOW priority so gitsigns/LSP always win a contested line
-- (a sign column shows one sign per line — the highest priority wins).
-- The range note's TEXT hangs below the range END (row end_line-1) in the
-- range namespace — the review-thread convention: the tinted block stays
-- contiguous and the note reads after it. (range_ns + helpers hoisted above.)
-- ===========================================================================

-- 13a. placement policy: a note on LINE 1 must render BELOW the line — the
-- regression pin for "a comment on line 1 was invisible" (virt_lines above a
-- line-1 anchor land outside the window's renderable range)
write_file(DATA .. '/demo13.lua',
  'local p = 1\nlocal q = 2\nlocal r = 3\nlocal s = 4\nlocal t = 5\nlocal u = 6\n')
mg.setup { persist = true, json_path = DATA .. '/p13.json', range_marker = 'tint' }
assert(vim.fn.hlexists('MarginaliaRange') > 0, '13a: MarginaliaRange highlight defined')
vim.cmd('edit ' .. vim.fn.fnameescape(DATA .. '/demo13.lua'))
local b13 = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb('first line note') end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.add_comment()
local l1 = vim.api.nvim_buf_get_extmarks(b13, ns, 0, -1, { details = true })
assert(#l1 == 1, '13a: one note on line 1, got ' .. #l1)
assert(l1[1][2] == 0, '13a: anchored to row 0 (line 1)')
assert(l1[1][4].virt_lines_above == false,
  '13a: line-1 note renders BELOW the line (virt_lines_above == false)')
assert(l1[1][4].sign_text ~= nil and l1[1][4].sign_text ~= '',
  '13a: line-1 note keeps its sign')

-- 13b. default 'tint': a range note L3-L5 gets exactly ONE tint extmark
-- over rows 2..4 (end_row EXCLUSIVE = 5, so L5 is tinted too) plus ONE
-- range-text extmark at row 4 (below L5 — the range END), and no
-- continuation signs
vim.ui.input = function(opts, cb) cb('range note tint') end
vim.cmd('normal! 3GV2j')
mg.add_comment()
local raw13 = range_extmarks(b13)
assert(#raw13 == 2, '13b: tint default -> tint + range text, got ' .. #raw13)
local tint13, txt13 = nil, nil
for _, m in ipairs(raw13) do
  local d = range_details(b13, m[1])
  if d.hl_group == 'MarginaliaRange' then tint13 = { row = m[2], d = d }
  elseif d.virt_lines then txt13 = { row = m[2], d = d } end
end
assert(tint13 ~= nil and tint13.row == 2, '13b: tint starts at row 2 (line 3), got '
  .. tostring(tint13 and tint13.row))
assert(tint13.d.end_row == 5,
  ('13b: tint spans rows 2..4 INCLUSIVE (L3-L5), got end_row %d (exclusive)')
    :format(tint13.d.end_row or -1))
assert(tint13.d.hl_group == 'MarginaliaRange', '13b: tint uses MarginaliaRange')
assert(tint13.d.hl_eol == true, '13b: tint fills to end of line (hl_eol)')
-- hl_mode='combine' (tint sits UNDER the syntax highlighting) is not
-- exposed back through the API — verifying that stays on the manual pass.
assert(tint13.d.priority == 1, '13b: tint stays under syntax/LSP (priority 1)')
assert(tint13.d.sign_text == nil or tint13.d.sign_text == '',
  '13b: tint mode must not place continuation signs')
assert(txt13 ~= nil and txt13.row == 4,
  '13b: range text hangs below the range END (row 4 = L5), got row '
    .. tostring(txt13 and txt13.row))
assert(txt13.d.virt_lines_above == false,
  '13b: range text renders BELOW the range end')
assert(#(txt13.d.virt_lines or {}) == 1, '13b: one text line -> one virt row')
-- the range note's COMMENT extmark (ns) carries NO text — only the sign;
-- all its text lives in range_ns. (Otherwise text would render twice.)
local ns13 = vim.api.nvim_buf_get_extmarks(b13, ns, 0, -1, { details = true })
local rc13
for _, cm in ipairs(ns13) do
  if cm[2] == 2 then rc13 = cm end -- L3-L5 range note's comment extmark
end
assert(rc13 ~= nil and #(rc13[4].virt_lines or {}) == 0,
  '13b: range note comment extmark carries NO text (range_ns only)')

-- 13b2. a range note anchored on LINE 1: the text still hangs at the range
-- END (row end_line-1), so the line-1 invisibility trap cannot bite — unlike
-- an above-the-line note, this placement is never at the buffer top. Its own
-- buffer+store: line 1 already hosts 13a's note, and the anchor line is
-- one-note-per-line. p13.json is flushed BEFORE the path switch and restored
-- after, so the 13c re-setup still re-renders b13 from its own store.
mg.flush_store() -- p13.json ('first line note', 'range note tint') lands
mg.setup { persist = true, json_path = DATA .. '/p13b2.json', range_marker = 'tint' }
write_file(DATA .. '/demo13b2.lua', 'local p2 = 1\nlocal q2 = 2\nlocal r2 = 3\nlocal s2 = 4\n')
vim.cmd('edit ' .. vim.fn.fnameescape(DATA .. '/demo13b2.lua'))
local b13b2 = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb('top range') end
vim.cmd('normal! 1GV2j') -- L1-L3
mg.add_comment()
local raw13b2 = range_extmarks(b13b2)
assert(#raw13b2 == 2, '13b2: line-1 range -> tint + range text, got ' .. #raw13b2)
local t13b2, x13b2 = nil, nil
for _, m in ipairs(raw13b2) do
  local d = range_details(b13b2, m[1])
  if d.hl_group == 'MarginaliaRange' then t13b2 = { row = m[2], d = d }
  elseif d.virt_lines then x13b2 = { row = m[2], d = d } end
end
assert(t13b2 ~= nil and t13b2.row == 0 and t13b2.d.end_row == 3,
  '13b2: line-1 tint covers rows 0..2 (L1-L3), got row '
    .. tostring(t13b2 and t13b2.row) .. ' end_row ' .. tostring(t13b2 and t13b2.d.end_row))
assert(x13b2 ~= nil and x13b2.row == 2 and x13b2.d.virt_lines_above == false,
  '13b2: line-1 range text hangs below L3 (range end, row 2), got row '
    .. tostring(x13b2 and x13b2.row))
mg.flush_store() -- p13b2.json lands; switch back so 13c re-renders b13's notes
mg.setup { persist = true, json_path = DATA .. '/p13.json', range_marker = 'tint' }
-- Return to demo13.lua (b13) — all subsequent phases toggle/edit on this buffer
vim.cmd('edit ' .. vim.fn.fnameescape(DATA .. '/demo13.lua'))

-- 13c. 'signs': a '│' continuator on every non-anchor range line (rows 3..4
-- for L4-L5), low priority, shared sign highlight; no tint extmark; the
-- range-TEXT extmark still hangs at the range end (it is not a sign)
mg.flush_store() -- debounced write lands so the re-setup restore re-renders
mg.setup { persist = true, json_path = DATA .. '/p13.json', range_marker = 'signs' }
raw13 = range_extmarks(b13)
assert(#raw13 == 3, '13c: signs mode -> two signs + range text, got ' .. #raw13)
local rows13 = {}
for _, m in ipairs(raw13) do rows13[m[2]] = true end
assert(rows13[3] and rows13[4],
  '13c: continuators sit on rows 3 and 4 (lines 4..5), got rows '
  .. table.concat(rows13 and vim.tbl_keys(rows13) or {}, ','))
local sign13, txt13c = 0, nil
for _, m in ipairs(raw13) do
  local d = range_details(b13, m[1])
  if d.virt_lines then
    -- the range text extmark: a virt-lined extmark, NOT a sign
    txt13c = { row = m[2], d = d }
    assert(m[2] == 4, '13c: range text still sits at the range end (row 4)')
    assert(d.virt_lines_above == false, '13c: range text below the range end')
  else
    sign13 = sign13 + 1
    -- nvim pads single-cell signs to two cells ("│ "), so compare the glyph
    assert((d.sign_text or ''):find('│', 1, true),
      '13c: continuation sign glyph is the box-draw bar')
    assert(d.sign_hl_group == 'MarginaliaSign', '13c: continuation sign highlight')
    assert(d.priority == 1,
      '13c: continuation signs yield to gitsigns/LSP (priority 1)')
    assert(d.hl_group == nil or d.hl_group == '', '13c: signs mode adds no tint')
  end
end
assert(sign13 == 2, '13c: exactly two continuator signs, got ' .. sign13)
assert(txt13c ~= nil, '13c: range text extmark present in signs mode')

-- 13d. 'both': the tint over rows 2..4 AND the two continuators AND the
-- range text at row 4 = 4 extmarks total
mg.flush_store()
mg.setup { persist = true, json_path = DATA .. '/p13.json', range_marker = 'both' }
raw13 = range_extmarks(b13)
assert(#raw13 == 4, '13d: both -> tint + two signs + range text, got ' .. #raw13)
local tint13, sig13, txt13d = nil, 0, nil
for _, m in ipairs(raw13) do
  local d = range_details(b13, m[1])
  if d.hl_group == 'MarginaliaRange' then
    tint13 = { row = m[2], d = d }
  elseif (d.sign_text or ''):find('│', 1, true) then
    sig13 = sig13 + 1
  elseif d.virt_lines then
    txt13d = { row = m[2], d = d }
  end
end
assert(tint13 ~= nil and tint13.row == 2 and tint13.d.end_row == 5,
  '13d: exactly one tint over rows 2..4 inclusive (end_row exclusive = 5)')
assert(sig13 == 2, '13d: both continuators present, got ' .. sig13)
assert(txt13d ~= nil and txt13d.row == 4,
  '13d: range text at the range end (row 4), got row ' .. tostring(txt13d and txt13d.row))

-- 13e. toggle off blanks the range marks; toggle on rebuilds them
-- exactly (no duplicates, no leftovers)
mg.toggle_comments()
assert(#range_extmarks(b13) == 0, '13e: hidden -> range marks blanked')
mg.toggle_comments()
assert(#range_extmarks(b13) == 4, '13e: shown -> range marks rebuilt, got '
  .. #range_extmarks(b13))

-- 13f. deleting the range comment removes its range marks (tint + signs)
vim.api.nvim_win_set_cursor(0, { 3, 0 })
mg.clear_current_comment()
assert(#range_extmarks(b13) == 0, '13f: delete -> range marks gone')
local after_del = vim.api.nvim_buf_get_extmarks(b13, ns, 0, -1, {})
assert(#after_del == 1, '13f: only the line-1 note remains, got ' .. #after_del)

-- 13g. unknown range_marker -> warn (naming the option) and fall back to
-- the tint, so an invalid value never crashes and never disables the range
reset_warnings()
mg.setup { persist = true, json_path = DATA .. '/p13h.json', range_marker = 'explode' }
assert(#WARNINGS == 1 and WARNINGS[1]:find('range_marker', 1, true) ~= nil,
  '13g: unknown range_marker must warn and name the option, got: '
  .. table.concat(WARNINGS, '; '))
reset_warnings()
write_file(DATA .. '/demo13h.lua', 'local h1 = 1\nlocal h2 = 2\nlocal h3 = 3\nlocal h4 = 4\n')
vim.cmd('edit ' .. vim.fn.fnameescape(DATA .. '/demo13h.lua'))
local bh = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb('fallback tint note') end
vim.cmd('normal! 2GV1j')
mg.add_comment()
raw13 = range_extmarks(bh)
assert(#raw13 == 2, '13g: invalid option falls back to tint + range text, got ' .. #raw13)
local fallback_tint = false
for _, m in ipairs(raw13) do
  if range_details(bh, m[1]).hl_group == 'MarginaliaRange' then
    fallback_tint = true
  end
end
assert(fallback_tint, '13g: invalid option falls back to the tint')

-- 13h. coexistence with foreign signs (gitsigns/LSP draw on the same rows):
-- our operations must never touch other namespaces. A "gitsigns-like" sign
-- (high priority, foreign namespace) shares a row with our continuator:
-- both survive add/toggle/delete — neither side destroys the other. Which
-- one NVIM displays on a contested row is nvim's priority decision; our
-- contract is priority 1 + clean coexistence, and only the latter is
-- observable headlessly.
write_file(DATA .. '/demo13g.lua',
  'local g1 = 1\nlocal g2 = 2\nlocal g3 = 3\nlocal g4 = 4\nlocal g5 = 5\n')
mg.setup { persist = true, json_path = DATA .. '/p13.json', range_marker = 'both' }
vim.cmd('edit ' .. vim.fn.fnameescape(DATA .. '/demo13g.lua'))
local bg_ = vim.api.nvim_get_current_buf()
local foreign_ns = vim.api.nvim_create_namespace 'marginalia_test_foreign'
vim.api.nvim_buf_set_extmark(bg_, foreign_ns, 2, 0, { sign_text = 'F', priority = 100 })
vim.api.nvim_buf_set_extmark(bg_, foreign_ns, 3, 0, { sign_text = 'F', priority = 100 })
vim.ui.input = function(opts, cb) cb('coexist note') end
vim.cmd('normal! 1GV2j') -- range L1-L3 -> our continuators on rows 1..2
mg.add_comment()
local function rows_of(buf, nsp)
  local set, list = {}, vim.api.nvim_buf_get_extmarks(buf, nsp, 0, -1, {})
  for _, m in ipairs(list) do set[m[2]] = true end
  return set
end
local our13h = rows_of(bg_, range_ns)
local foreign13h = rows_of(bg_, foreign_ns)
assert(our13h[2] and foreign13h[2],
  '13h: contested row 2 carries BOTH our continuator and the foreign sign')
assert(foreign13h[2] and foreign13h[3], '13h: foreign signs untouched by add')
mg.toggle_comments()
assert(#range_extmarks(bg_) == 0, '13h: toggle off blanks only OUR range marks')
foreign13h = rows_of(bg_, foreign_ns)
assert(foreign13h[2] and foreign13h[3],
  '13h: foreign signs survive toggle off')
mg.toggle_comments()
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.clear_current_comment()
assert(#range_extmarks(bg_) == 0, '13h: delete clears only our range marks')
foreign13h = rows_of(bg_, foreign_ns)
assert(foreign13h[2] and foreign13h[3],
  '13h: foreign signs survive comment deletion')

-- ===========================================================================
-- PHASE 14: project-scoped bulk delete — clear_project_comments wipes every
-- comment in the current PROJECT (files under cfg.project_root, the
-- directory nvim was opened in) in one call. Comments belonging to other
-- projects (files outside the root) are untouched.
-- ===========================================================================
local PROJ = DATA .. '/proj14'
vim.fn.mkdir(PROJ, 'p')
local FOREIGN14 = DATA .. '/proj14f.lua'
write_file(PROJ .. '/demo14.lua', 'local a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 4\n')
write_file(FOREIGN14, 'local x1 = 1\nlocal x2 = 2\nlocal x3 = 3\nlocal x4 = 4\n')
mg.flush_store()
mg.setup { persist = true, json_path = DATA .. '/p14.json', project_root = PROJ }

-- project file: three notes — L1 single, L3 single, L2-L3 range
vim.cmd('edit ' .. vim.fn.fnameescape(PROJ .. '/demo14.lua'))
local b14 = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb('fourteen a') end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.add_comment()
vim.ui.input = function(opts, cb) cb('fourteen b') end
vim.api.nvim_win_set_cursor(0, { 3, 0 })
mg.add_comment()
vim.ui.input = function(opts, cb) cb('fourteen range') end
vim.cmd('normal! 2GV1j') -- L2-L3 (anchor L2, range to L3)
mg.add_comment()
local proj_marks = vim.api.nvim_buf_get_extmarks(b14, ns, 0, -1, {})
assert(#proj_marks == 3, '14: project file has 3 comments, got ' .. #proj_marks)
assert(#range_extmarks(b14) == 2,
  '14: project range note has tint + text range marks, got ' .. #range_extmarks(b14))

-- foreign file: two notes (outside project_root) — must survive the wipe
vim.cmd('edit ' .. vim.fn.fnameescape(FOREIGN14))
local b14f = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb('foreign one') end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
mg.add_comment()
vim.ui.input = function(opts, cb) cb('foreign two') end
vim.api.nvim_win_set_cursor(0, { 3, 0 })
mg.add_comment()
local foreign_marks = vim.api.nvim_buf_get_extmarks(b14f, ns, 0, -1, {})
assert(#foreign_marks == 2, '14: foreign file has 2 comments, got ' .. #foreign_marks)

mg.flush_store()
local p14_pre = read_store(DATA .. '/p14.json')
assert(#(p14_pre.files[PROJ .. '/demo14.lua'] or {}) == 3
    and #(p14_pre.files[FOREIGN14] or {}) == 2,
  '14: store holds 5 entries before the wipe (3 project + 2 foreign)')
local scoped_coll = mg.get_all_comments()
assert(#scoped_coll == 3,
  '14: collection is scoped to the project (foreign excluded), got ' .. #scoped_coll)
assert(vim.fn.maparg('<leader>RC', 'n') ~= '', '14: clear_project keymap registered')

-- the button: wipe every comment whose file is under the project root
mg.clear_project_comments()

-- project file: extmarks gone, range marks gone, store entry nil
proj_marks = vim.api.nvim_buf_get_extmarks(b14, ns, 0, -1, {})
assert(#proj_marks == 0, '14: project extmarks wiped, got ' .. #proj_marks)
assert(#range_extmarks(b14) == 0, '14: project range marks wiped too')

-- foreign file: untouched (both extmarks and store)
foreign_marks = vim.api.nvim_buf_get_extmarks(b14f, ns, 0, -1, {})
assert(#foreign_marks == 2, '14: foreign extmarks untouched, got ' .. #foreign_marks)
mg.flush_store()
local p14 = read_store(DATA .. '/p14.json')
assert(p14.files[FOREIGN14] ~= nil and #p14.files[FOREIGN14] == 2,
  '14: store retains only the foreign path with 2 entries')
assert(p14.files[PROJ .. '/demo14.lua'] == nil,
  '14: project path removed from store')
assert(#mg.get_all_comments() == 0,
  '14: scoped collection empty after the wipe (foreign lives, but out of scope)')

-- a second call warns (project is now clean)
reset_warnings()
mg.clear_project_comments()
assert(reset_warnings() == 1, '14: clear_project on clean project must warn')

-- clean up
vim.cmd('bdelete! ' .. b14)
vim.cmd('bdelete! ' .. b14f)
vim.fn.delete(PROJ, 'rf')
vim.fn.delete(FOREIGN14)

print('CORE TESTS PASSED')
vim.cmd('qa!')
