#!/usr/bin/env bash
# Stop：写过知识笔记就必须先通过去 AI 味检查，否则拦住不让收工。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IN=$(cat)

SID=$(printf '%s' "$IN" | jq -r '.session_id // "unknown"')
D="$ROOT/.claude/.状态"
PEND="$D/$SID.待检"
ROUND="$D/$SID.轮次"

[ -s "$PEND" ] || exit 0        # 没写过笔记，或已通过并清空 → 放行

N=$(cat "$ROUND" 2>/dev/null || echo 0)
if [ "$N" -ge 3 ]; then          # 逃生阀：不让误报把人永久困住
  rm -f "$PEND" "$ROUND"
  jq -n '{systemMessage:"去 AI 味检查已达 3 轮上限，本次放行。若仍有问题请手动说「检查 AI 味」。"}'
  exit 0
fi
printf '%s\n' $((N+1)) > "$ROUND"

FILES=$(sed 's/^/  - /' "$PEND")
jq -n --arg files "$FILES" --arg round "$((N+1))" --arg pend "$PEND" --arg rd "$ROUND" '
{
  decision: "block",
  reason: (
    "【收尾关卡 · 第 " + $round + "/3 轮】本次会话写了以下知识笔记，收工前必须先过去 AI 味检查：\n" +
    $files + "\n\n" +
    "现在用 Agent 工具启动子 agent，subagent_type 填 \"humanizer-check\"，" +
    "把上面每个文件的路径交给它检查。它是只读的，只会返回评分和问题清单，不会改文件。\n\n" +
    "拿到报告后：\n" +
    "· 判定「未通过」→ 按报告逐条修改笔记，改完直接结束本轮，本关卡会再次触发并复查。\n" +
    "· 判定「通过」（总分 ≥45）→ 先把报告里的评分简要转述给用户，再执行：\n" +
    "    rm -f \"" + $pend + "\" \"" + $rd + "\"\n" +
    "  然后才可以结束工作。\n\n" +
    "注意：命中「技术笔记豁免」的条目不要改 —— 把结构良好的参数列表改成流水段落是倒退。" +
    "如果你判断某条报告是误报，说明理由并保留原文即可，不必强行迎合评分。"
  )
}'
exit 0
