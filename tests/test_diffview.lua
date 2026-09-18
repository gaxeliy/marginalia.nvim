-- marginalia.nvim — diffview.nvim integration test (conditional).
-- Requires diffview.nvim loadable on the runtimepath; if absent (or its
-- deps are missing), prints a WARNING and skips (per project policy).
-- When present, runs a REAL diff view scenario and asserts hard.
local DATA = '/tmp/opencode/mg_dv_data'
vim.fn.delete(DATA, 'rf')
vim.fn.mkdir(DATA, 'p')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function find_dir(name)
  local candidates = {
    vim.fs.joinpath(vim.fn.stdpath 'data', 'site/pack/core/opt', name),
    vim.fs.joinpath(vim.fn.stdpath 'data', 'lazy', name),
  }
  for _, d in ipairs(candidates) do
    if vim.fn.isdirectory(d) == 1 then return d end
  end
  return nil
end

local function skip(msg)
  print('WARNING: ' .. msg)
  vim.defer_fn(function() vim.cmd('qa!') end, 100)
end

local dv_dir = find_dir('diffview.nvim')
if not dv_dir then
  return skip('diffview.nvim not installed — skipping diffview integration tests')
end
vim.opt.runtimepath:append(dv_dir)
-- diffview needs an icon provider; without it require() fails -> skip
if not pcall(require, 'diffview') then
  return skip('diffview.nvim present but not loadable (missing dependency, '
    .. 'e.g. nvim-web-devicons) — skipping diffview tests')
end
-- plugin/ scripts (registering the :DiffviewOpen command) were not sourced at
-- startup because the plugin was appended to the runtimepath afterwards.
vim.cmd('runtime! plugin/diffview.lua')
if vim.fn.exists(':DiffviewOpen') == 0 then
  return skip('diffview.nvim loaded but :DiffviewOpen not registered — skipping diffview tests')
end
if vim.fn.executable('git') == 0 then
  return skip('git not available — skipping diffview tests')
end

-- ===========================================================================
local mg = require('marginalia')
local ns = vim.api.nvim_create_namespace('marginalia_comments')
vim.ui.input = function(opts, cb) cb('diffview note') end

local repo = DATA .. '/repo'
vim.fn.delete(repo, 'rf')
vim.fn.mkdir(repo, 'p')
local setup = os.execute(
  'cd ' .. repo .. ' && git init -q .'
  .. ' && git config user.email t@t.t && git config user.name t'
  .. " && printf 'alpha\\nbeta\\ngamma\\n' > f.lua"
  .. ' && git add -A && git commit -qm init'
  .. " && printf 'alpha\\nbeta CHANGED\\ngamma\\n' > f.lua"
)
assert(setup == 0 or setup == true, 'git repo setup failed')

vim.cmd('cd ' .. vim.fn.fnameescape(repo))
vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/f.lua'))
local file_buf = vim.api.nvim_get_current_buf()

-- setup AFTER :cd: project_root defaults to the repo, so the scoped
-- collection (get_all_comments) sees the diffview buffers.
mg.setup { persist = false } -- diffview buffers must accept notes out of the box

-- open the diff view; the worktree copy of f.lua is the right pane
local open_ok, open_err = pcall(vim.cmd, 'DiffviewOpen')
assert(open_ok, 'DiffviewOpen failed: ' .. tostring(open_err))

local function find_worktree_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if b == file_buf and vim.api.nvim_buf_is_loaded(b) then
      return w
    end
  end
  return nil
end

assert(vim.wait(3000, find_worktree_window, 30), 'worktree file window not shown in diffview')

vim.api.nvim_set_current_win(find_worktree_window())
vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- 'beta CHANGED'
mg.add_comment()

-- 1. the comment landed in the diffview worktree buffer
local marks = vim.api.nvim_buf_get_extmarks(file_buf, ns, 0, -1, { details = true })
assert(#marks == 1, 'one comment in diffview buffer, got ' .. #marks)
assert(marks[1][2] == 1, 'anchored to L2 (row 1), got row ' .. marks[1][2])
assert(marks[1][4].sign_hl_group == 'MarginaliaSign', 'sign rendered in diffview buffer')

-- 2. collection reports the real file path
local collected
for _, c in ipairs(mg.get_all_comments()) do
  if c.abspath == repo .. '/f.lua' then collected = c end
end
assert(collected ~= nil, 'diffview comment collected with the real file path')
assert(collected.line == 2, 'diffview comment at L2, got ' .. tostring(collected.line))

-- 3. export with cwd = repo: relpath is just 'f.lua'
mg.export_to_clipboard()
local reg = vim.fn.getreg('+')
assert(reg:find('f%.lua:2 diffview note'), 'export uses repo-relative path: ' .. reg)

-- 4. comment survives a view toggle (hide/show inside diffview)
mg.toggle_comments()
marks = vim.api.nvim_buf_get_extmarks(file_buf, ns, 0, -1, { details = true })
assert(#(marks[1][4].virt_lines or {}) == 0, 'hide works in diffview buffer')
mg.toggle_comments()
marks = vim.api.nvim_buf_get_extmarks(file_buf, ns, 0, -1, { details = true })
assert(#(marks[1][4].virt_lines or {}) == 1, 'show works in diffview buffer')

-- cleanup
pcall(vim.cmd, 'DiffviewClose')
vim.fn.delete(repo, 'rf')
print('DIFFVIEW TESTS PASSED')
vim.defer_fn(function() vim.cmd('qa!') end, 200)
