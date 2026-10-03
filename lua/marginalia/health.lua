-- :checkhealth marginalia — verifies the environment the plugin runs in.
-- The module path follows the :checkhealth convention:
-- lua/marginalia/health.lua, entry point M.check().
local M = {}

local function clipboard_provider()
  if vim.g.clipboard ~= nil then
    return 'g:clipboard (user-defined provider)'
  end
  local ok, exe = pcall(vim.fn['provider#clipboard#Executable'])
  if ok and type(exe) == 'string' and exe ~= '' then
    return exe
  end
  return nil
end

local function check_persistence(cfg)
  if not cfg.persist then
    vim.health.ok('persist = false: comments are session-only')
    return
  end
  local path = cfg.json_path
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.health.warn('store directory does not exist yet: ' .. dir,
      { 'It will be created on the first save when possible' })
    return
  end
  if vim.fn.filewritable(dir) ~= 2 then
    vim.health.error('store directory is not writable: ' .. dir)
    return
  end
  if vim.fn.filereadable(path) == 1 and vim.fn.filewritable(path) ~= 1 then
    vim.health.error('store file is not writable: ' .. path)
    return
  end
  vim.health.ok('store: ' .. path)
end

--- Entry point called by `:checkhealth marginalia`.
function M.check()
  vim.health.start('marginalia')

  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim >= 0.10')
  else
    vim.health.error('Neovim >= 0.10 is required', {
      'Upgrade Neovim: https://github.com/neovim/neovim/releases',
    })
  end

  local ok, mg = pcall(require, 'marginalia')
  if not ok then
    vim.health.error('the marginalia module failed to load: ' .. tostring(mg))
    return
  end
  local cfg = mg._config()
  if cfg == nil then
    vim.health.warn('setup() has not been called', {
      "Add require('marginalia').setup {} to your config",
    })
  else
    vim.health.ok('setup() called (project_root: ' .. cfg.project_root .. ')')
    check_persistence(cfg)
  end

  local provider = clipboard_provider()
  if provider then
    vim.health.ok('clipboard provider for "+": ' .. provider)
  else
    vim.health.warn('no clipboard provider for the "+" register', {
      'Export falls back to the unnamed register',
      'Install xclip/wl-copy, or see :checkhealth provider',
    })
  end

  if pcall(require, 'telescope') then
    vim.health.ok('telescope.nvim found: picker enabled')
  else
    vim.health.info('telescope.nvim not found: the quickfix fallback is used')
  end
  if pcall(require, 'which-key') then
    vim.health.ok('which-key.nvim found: [R]eview group label')
  else
    vim.health.info('which-key.nvim not found (optional)')
  end
end

return M
