#!/usr/bin/env bash
# Run the test suite against multiple Neovim versions using official portable
# builds. The system Neovim is never touched: builds are cached under
# ${XDG_CACHE_HOME:-~/.cache}/marginalia.nvim/nvim-versions.
#
# Each version runs with an isolated XDG_DATA_HOME by default, so the matrix
# tests THIS plugin rather than whatever telescope/diffview happen to be
# installed (old Neovim + new telescope can be incompatible). Set
# MATRIX_SYSTEM_PLUGINS=1 to use the real data dir and run the integration
# suites too.
#
#   tests/matrix.sh                 # default pinned versions
#   tests/matrix.sh v0.11.7 stable  # explicit list
#
# CI runs the same matrix via .github/workflows/tests.yml.
set -u
cd "$(dirname "$0")/.."

DEFAULT_VERSIONS=(v0.10.4 v0.11.7 v0.12.5)
VERSIONS=("$@")
if [ ${#VERSIONS[@]} -eq 0 ]; then
  VERSIONS=("${DEFAULT_VERSIONS[@]}")
fi

case "$(uname -m)" in
  x86_64) ASSET=nvim-linux-x86_64 ;;
  aarch64|arm64) ASSET=nvim-linux-arm64 ;;
  *) echo "matrix: unsupported architecture: $(uname -m)"; exit 1 ;;
esac

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/marginalia.nvim/nvim-versions"
mkdir -p "$CACHE"

fetch() { # version dir
  local v="$1" dir="$2" url tmp
  if [ -x "$dir/bin/nvim" ]; then return 0; fi
  url="https://github.com/neovim/neovim/releases/download/$v/$ASSET.tar.gz"
  tmp="$dir.tar.gz"
  echo "matrix: downloading $v ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url" || return 1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || return 1
  else
    echo "matrix: curl or wget is required"
    return 1
  fi
  mkdir -p "$dir"
  tar -xzf "$tmp" -C "$dir" --strip-components=1 || return 1
  rm -f "$tmp"
}

failed=()
for v in "${VERSIONS[@]}"; do
  dir="$CACHE/$v"
  if ! fetch "$v" "$dir"; then
    echo "FAIL  $v (download/extract)"
    failed+=("$v")
    continue
  fi
  printf '\n== %s (%s) ==\n' "$v" "$("$dir/bin/nvim" --version | head -1)"
  if [ "${MATRIX_SYSTEM_PLUGINS:-0}" = "1" ]; then
    data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  else
    data_home="$CACHE/xdg-$v"
    mkdir -p "$data_home"
  fi
  if PATH="$dir/bin:$PATH" XDG_DATA_HOME="$data_home" bash tests/run.sh; then
    echo "OK    $v"
  else
    echo "FAIL  $v"
    failed+=("$v")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "matrix: failed on: ${failed[*]}"
  exit 1
fi
echo "matrix: all ${#VERSIONS[@]} version(s) passed"
