-- marginalia.nvim — fuzz test for the store loader (conditional-free).
-- The JSON store is the plugin's only external input surface: throw a fixed
-- seed's worth of garbage and malformed-but-plausible shapes at setup() and
-- demand the impossible-to-violate invariants:
--   1. setup() never raises (corrupt input -> empty store, never a crash)
--   2. get_all_comments() afterwards always returns a sane, sorted list
--   3. flush_store() never crashes
-- Deterministic: math.randomseed is fixed, so every run mutates identically.
local DATA = '/tmp/opencode/mg_fuzz_data'
vim.fn.delete(DATA, 'rf')
vim.fn.mkdir(DATA, 'p')
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local mg = require('marginalia')
math.randomseed(42)

local ALPHABET = {
  '{', '}', '[', ']', ':', ',', '"', '\\', '1', '0', '-', 'e', 'n', ' ', '\n',
  'files', 'version', 'true', 'false', 'null', 'line', 'text', 'anchor', 'uid',
  '中', '🚀', 'é́', -- unicode fragments: the loader must treat them as bytes
}

-- deterministic pseudo-random byte/fragment soup
local function rnd(n)
  local out = {}
  for _ = 1, n do
    local r = math.random(0, #ALPHABET)
    out[#out + 1] = ALPHABET[r]
  end
  return table.concat(out)
end

-- start from a valid store and mutate it like a fuzzer would
local function mutate_json(json)
  local b = { json:byte(1, #json) }
  for _ = 1, math.random(1, 4) do
    local op = math.random(1, 3)
    local pos = math.random(1, math.max(1, #json))
    if op == 1 then -- delete a char
      table.remove(b, pos)
    elseif op == 2 then
      table.insert(b, pos, string.byte(ALPHABET[math.random(1, #ALPHABET)]))
    else
      b[pos] = string.byte(ALPHABET[math.random(1, #ALPHABET)])
    end
  end
  return string.char(unpack(b))
end

local VALID = vim.json.encode {
  version = 1,
  files = { [DATA .. '/fuzz_target.lua'] = {
    { line = 2, end_line = 2, text = 'seeded note', anchor = 'local b = 2', uid = 9 },
  } },
}

local iterations = 80
local crashes = 0
for i = 1, iterations do
  local payload
  if i % 4 == 1 then
    payload = rnd(math.random(0, 40)) -- pure soup
  elseif i % 4 == 2 then
    payload = mutate_json(VALID) -- byte-level JSON mutations
  elseif i % 4 == 3 then
    payload = '{"version":1,"files":{' .. rnd(6) .. ':[{"line":'
      .. math.random(-5, 15) .. ',"text":"' .. rnd(8) .. '","uid":'
      .. math.random(0, 12) .. '}]}}' -- semi-valid store-like shapes
  else
    payload = VALID -- control: valid input must actually load
  end
  local target = DATA .. '/fuzz_target.lua'
  local fh = io.open(target, 'w')
  fh:write('local a = 1\nlocal b = 2\nlocal c = 3\n')
  fh:close()

  local store_path = DATA .. '/store.json'
  local sfh = io.open(store_path, 'w')
  sfh:write(payload)
  sfh:close()

  local ok, err = pcall(mg.setup, { persist = true, json_path = store_path,
    project_root = DATA })
  if not ok then
    crashes = crashes + 1
    print(('CRASH on iteration %d: %s\npayload: %s'):format(i, tostring(err), payload))
    break
  end
  local ok2, err2 = pcall(function()
    local comments = mg.get_all_comments()
    assert(type(comments) == 'table', 'collection must be a list')
    for j = 2, #comments do
      if comments[j].abspath == comments[j - 1].abspath then
        assert(comments[j].line >= comments[j - 1].line, 'collection must stay sorted')
      end
    end
    mg.flush_store()
  end)
  if not ok2 then
    crashes = crashes + 1
    print(('INVARIANT VIOLATION on iteration %d: %s\npayload: %s')
      :format(i, tostring(err2), payload))
    break
  end
end

assert(crashes == 0, 'store loader must tolerate arbitrary input without crashing')
print('FUZZ TESTS PASSED (' .. iterations .. ' payloads, seed 42)')
vim.cmd('qa!')
