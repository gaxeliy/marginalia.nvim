#!/usr/bin/env bash
# Mutation testing for marginalia.nvim — homegrown, no frameworks.
#
# For each mutation below: apply it to lua/marginalia/init.lua, run the core
# suite, and EXPECT failure. A mutation that SURVIVES means no test pins the
# mutated behavior — a coverage hole (or a test that passes regardless).
#
# Mutation spec: name|description|old|new|nth-occurrence (default 1)
# Placeholders: %Q -> '   %D -> "
#
# Usage: tests/mutate.sh [mutation-name ...]   (default: all)
set -u
cd "$(dirname "$0")/.."

BACKUP="$(mktemp /tmp/marginalia_init_backup.XXXXXX)"
cp lua/marginalia/init.lua "$BACKUP"
restore() { cp "$BACKUP" lua/marginalia/init.lua; }
trap restore EXIT

MUTATIONS=(
  'virt_lines_above|range text placed above the range end again|virt_lines_above = false|virt_lines_above = true|1'
  'virt_lines_above_comment|comment text placed above the line again (comment extmark)|virt_lines_above = false|virt_lines_above = true|2'
  'range_tint|range tint highlight dropped|end_row = end_line|end_row = line - 1|1'
  'range_text|range note text moved from below the range end back to the anchor line|range_ns, end_line - 1, 0, {|range_ns, line - 1, 0, {|1'
  'range_text_dropped|range note text extmark loses its content|virt_lines = build_virt_lines(text, line, end_line),|virt_lines = {},|1'
  'range_signs|continuation signs dropped|sign_text = %Q│%Q|sign_text = %Q%Q|1'
  'range_priority|range markers stop yielding (priority raised)|RANGE_PRIORITY = 1|RANGE_PRIORITY = 100|1'
  'sign_hl|sign highlight group dropped|sign_hl_group = visible and %QMarginaliaSign%Q or nil|sign_hl_group = nil|1'
  'self_heal|live extmarks stop syncing into the store|m[1], true)|m[1], false)|1'
  'dup_refusal|one-note-per-line refusal removed|if find_comment_at_line(bufnr, line) then|if false then|1'
  'no_warn|clipboard warning never fires|if not clipboard_available() then|if false then|1'
  'no_fallback|unnamed-register fallback write removed|vim.fn.setreg(%Q%D%Q, text) -- fallback|do end|1'
  'anchor_fallback|anchor-miss fallback reports a match and overwrites the anchor|return wanted, false|return wanted, true|2'
  'eof_clamp|EOF clamp removed|line = math.max(1, math.min(line, line_count))|line = line|1'
  'end_line_clamp|end_line < line clamp at load removed|math.max(line, tonumber(e.end_line) or line)|tonumber(e.end_line) or line|1'
  'uid_reassign|uid == 0 reassignment removed|if uid == 0 then|if false then|1'
  'version_check|version validation removed|data.version ~= 1|false|1'
  'unmap|stale mapping cleanup removed|pcall(vim.keymap.del, mk[1], mk[2])|do end|1'
  'edit_interrupt|edit_comment interrupt guard removed|if not ok or new_text == CANCEL|if new_text == CANCEL|1'
  'always_visible|hidden state ignored on restore|not hidden[e.uid]|true|1'
  'on_hover|on_hover autocmd branch removed|if cfg.preview and cfg.preview.on_hover then|if false then|1'
  'preview_cap|20-line preview content cap removed|math.min(#content, 20)|#content|1'
  'rb_guard|unsaved review edits guard removed|if vim.bo[review_buf].modified then|if false then|1'
  'rb_copy|copy_review stops sending content|vim.fn.setreg(%Q+%Q, table.concat(ls, %Q\n%Q))|do end|2'
  'empty_dict|empty-store object encoding broken|vim.empty_dict()|{}|1'
  'custom_provider|g:clipboard check removed|if vim.g.clipboard ~= nil then return true end|if false then return true end|1'
  'project_scope|collection no longer scoped to the project root|if in_project(c.abspath, root) then|if true then|1'
  'clear_project_partial|project wipe deletes only the first comment|for _, m in ipairs(marks) do|for _, m in ipairs({ marks[1] }) do|2'
  'clear_project_no_warn|wipe on an empty project no longer warns|if removed == 0 then|if false then|1'
)

run_core() {
  # second -c guarantees exit even when the mutated suite errors mid-way
  nvim --headless -u NONE -n -c "luafile tests/test_core.lua" -c "qa!" 2>&1 | grep -q "CORE TESTS PASSED"
}

apply() { # file old new nth — replaces the nth (1-based) occurrence
  python3 - "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
path, old, new, nth = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
src = open(path).read()
idx = -1
for _ in range(nth):
    idx = src.find(old, idx + 1)
    if idx == -1:
        sys.exit(1)
open(path, 'w').write(src[:idx] + new + src[idx + len(old):])
PYEOF
}

filter="${*:-}"
survivors=0
for spec in "${MUTATIONS[@]}"; do
  IFS='|' read -r name desc old new nth <<< "$spec"
  if [ -n "${filter:-}" ] && [ "$filter" != "$name" ]; then continue; fi
  SQ="'"
  DQ='"'
  old="${old//%Q/$SQ}"; old="${old//%D/$DQ}"
  new="${new//%Q/$SQ}"; new="${new//%D/$DQ}"
  restore
  if ! apply lua/marginalia/init.lua "$old" "$new" "${nth:-1}"; then
    echo "ERROR mutation $name: pattern not found (occurrence $nth)"
    survivors=$((survivors + 1))
    continue
  fi
  if run_core; then
    echo "SURVIVED  $name  ($desc)  <- no test pins this behavior"
    survivors=$((survivors + 1))
  else
    echo "killed    $name"
  fi
done
restore
echo "----"
echo "$survivors surviving mutation(s)"
if [ "$survivors" -gt 0 ]; then exit 1; fi
exit 0
