-- marginalia.nvim — Telescope integration test (conditional, async chain).
-- Requires telescope.nvim + plenary.nvim on the runtimepath; if absent,
-- prints a WARNING and skips (per project policy).
--
-- Queued nvim_input keys are NOT dispatched while vim.wait() is polling
-- (verified), so the test drives the picker through a defer_fn step chain:
-- every state assertion inside a step is synchronous and factual.
local DATA = '/tmp/opencode/mg_tsl_data'
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

if not find_dir('telescope.nvim') then
  return skip('telescope.nvim not installed — skipping Telescope integration tests')
end
if not find_dir('plenary.nvim') then
  return skip('plenary.nvim not installed — telescope.nvim cannot run — skipping')
end
vim.opt.runtimepath:append(find_dir('telescope.nvim'))
vim.opt.runtimepath:append(find_dir('plenary.nvim'))
if not pcall(require, 'telescope.pickers') then
  return skip('telescope.nvim present but not loadable — skipping Telescope tests')
end

-- ===========================================================================
local mg = require('marginalia')
local ns = vim.api.nvim_create_namespace('marginalia_comments')

local function telescope_present()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    local ft = vim.api.nvim_get_option_value('filetype', { buf = b })
    if ft == 'TelescopePrompt' or ft == 'TelescopeResults' then
      return true
    end
  end
  return false
end

-- previewer disabled in test: grep_previewer would spawn ripgrep
mg.setup { persist = false, project_root = DATA,
  telescope = { previewer = false } }

local path = DATA .. '/demo.lua'
local fh = io.open(path, 'w')
fh:write('local a = 1\nlocal b = 2\n')
fh:close()
vim.cmd('edit ' .. vim.fn.fnameescape(path))
local bufnr = vim.api.nvim_get_current_buf()
vim.ui.input = function(opts, cb) cb(opts.default or 'picker target') end
local real_input = vim.fn.input

local function count_marks()
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

-- tiny async engine: each step runs, then the chain continues after `delay`
local steps = {}
local idx = 0
local run_next -- forward declaration (single definition)

local function step(fn, delay) steps[#steps + 1] = { fn = fn, delay = delay or 250 } end

run_next = function()
  idx = idx + 1
  if not steps[idx] then
    print('TELESCOPE TESTS PASSED')
    vim.cmd('qa!')
    return
  end
  local s = steps[idx]
  local ok, err = pcall(s.fn)
  if not ok then
    print('TELESCOPE TEST FAILED at step ' .. idx .. ': ' .. tostring(err))
    vim.cmd('qa!')
    return
  end
  vim.defer_fn(run_next, s.delay)
end

step(function()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  mg.add_comment() -- 'picker target' at L2
  assert(count_marks() == 1, 'comment added')
end)

step(function()
  mg.pick_comments()
end, 300)

step(function()
  assert(vim.wait(3000, telescope_present, 20), 'prompt opened')
  vim.api.nvim_input('<CR>')
end, 250)

step(function()
  assert(vim.wait(3000, function() return not telescope_present() end, 30),
    'CR closed the picker')
  assert(vim.fn.line '.' == 2, 'CR jumped to the comment line, got ' .. vim.fn.line('.'))
end)

step(function()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  mg.pick_comments()
end, 300)

step(function()
  assert(vim.wait(3000, telescope_present, 20), 'prompt reopened')
  vim.api.nvim_input('<C-d>')
end, 250)

step(function()
  assert(vim.wait(3000, function()
    return not telescope_present() and count_marks() == 0
  end, 30), 'C-d closed the picker and deleted the comment')
end, 150)

step(function()
  -- re-add, then edit it through the picker
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.ui.input = function(opts, cb) cb('edit target') end
  mg.add_comment()
  vim.fn.input = function(o) return 'picker edited' end
  mg.pick_comments()
end, 300)

step(function()
  assert(vim.wait(3000, telescope_present, 20), 'prompt reopened for edit')
  vim.api.nvim_input('<C-e>')
end, 250)

step(function()
  assert(vim.wait(3000, function() return not telescope_present() end, 30),
    'C-e closed the picker')
  local edited
  for _, c in ipairs(mg.get_all_comments()) do
    if c.text == 'picker edited' then edited = c end
  end
  assert(edited ~= nil and edited.line == 2, 'C-e edited the selected comment in place')
  vim.fn.input = real_input
end)

run_next()
