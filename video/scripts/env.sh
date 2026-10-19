#!/bin/bash
# 반드시 source 로 읽는다. 모든 쓰기 경로를 이 worktree 안으로 격리한다.
VIDEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(cd "$VIDEO_ROOT/.." && pwd)"
VIDEO_NODE_BIN="$(dirname "$(command -v node || echo /usr/bin/node)")"
export HOME="$VIDEO_ROOT/.work/home"
export CFFIXED_USER_HOME="$HOME"
export AGENTDECK_APP_SUPPORT="$VIDEO_ROOT/.work/appsupport"
export AGENTDECK_HOME="$VIDEO_ROOT/.work/data"
export AGENTDECK_TERM_HOME="$AGENTDECK_HOME/term"
export CLAUDE_CONFIG_DIR="$VIDEO_ROOT/.work/claude"
export CODEX_HOME="$VIDEO_ROOT/.work/codex"
export AGENTDECK_CLAUDE_TMP="$VIDEO_ROOT/.work/tasks"
export AGENTDECK_NO_ACTIVATE=1
export AGENTDECK_NO_NOTIFY=1
export AGENTDECK_DEBUG=1
export AGENTDECK_DEBUG_NAME=dev.agentdeck.video.20261019.isolated
export AGENTDECK_SNAPSHOT="$VIDEO_ROOT/.work/snapshot"
export AGENTDECK_FAKE_LATEST=v0.4.0
export AGENTDECK_AUTO_TITLE=0
export TMPDIR="$VIDEO_ROOT/.work/tmp/"
export XDG_CACHE_HOME="$VIDEO_ROOT/.work/cache"
export CLANG_MODULE_CACHE_PATH="$VIDEO_ROOT/.work/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$VIDEO_ROOT/.work/cache/swift"
export ZDOTDIR="$HOME"
export SHELL=/bin/zsh
export PATH="$VIDEO_ROOT/.work/bin:$VIDEO_NODE_BIN:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME" "$AGENTDECK_APP_SUPPORT" "$AGENTDECK_TERM_HOME" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$AGENTDECK_CLAUDE_TMP" "$AGENTDECK_SNAPSHOT" "$TMPDIR" "$XDG_CACHE_HOME" "$VIDEO_ROOT/.work/bin"
