#!/usr/bin/env bash
# PostToolUse(Write|Edit)：记下本次会话写过哪些知识笔记，供收尾关卡使用。
# 只认 <学科>/<领域>/<文件>.md 这种恰好三段的路径，其余一律忽略。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IN=$(cat)

SID=$(printf '%s' "$IN" | jq -r '.session_id // "unknown"')
F=$(printf '%s' "$IN" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')
[ -n "$F" ] || exit 0

REL="${F#"$ROOT/"}"
[ "$REL" != "$F" ] || exit 0                          # 不在知识库里
[[ "$REL" =~ ^[^/]+/[^/]+/[^/]+\.md$ ]] || exit 0     # 必须恰好三段

case "$REL" in
  .claude/*|草稿箱/*|模板/*|日志/*|附件/*) exit 0 ;;  # 机制目录不是笔记
esac

D="$ROOT/.claude/.状态"; mkdir -p "$D"
grep -qxF "$REL" "$D/$SID.待检" 2>/dev/null || printf '%s\n' "$REL" >> "$D/$SID.待检"
exit 0
