#!/usr/bin/env bash
# Stop：笔记名和别名共用一个全局命名空间，撞车会让 [[双链]] 指向错误的笔记。
# 博客构建已经把它判成 fatal，但那是推送之后的事 —— 这里把同一道关卡提前到收工前，
# 代价是全库扫一遍 frontmatter（几十毫秒），换掉一次「推上去才发现部署红了」。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IN=$(cat)
cd "$ROOT" || exit 0

# 归一化对齐博客的 normalizeKey：去首尾空格 + 转小写（中文无大小写，只影响英文别名）。
# 同一篇内部先 sort -u，自己和自己不算撞。
# 只认 `aliases: [a, b]` 这种行内写法 —— 知识库一直这么写；真有人改成 YAML 列表式，
# 这里会漏掉，届时仍由构建兜底。
CONFLICTS=$(
  for f in */*/*.md; do
    [ -e "$f" ] || continue
    # 模式前的 ( 是 bash 3.2 的补丁：$( ) 里的 case 少了它会误判括号配对
    case "$f" in (草稿箱/*|模板/*|日志/*|附件/*) continue ;; esac
    {
      basename "$f" .md
      sed -n 's/^aliases: *\[\(.*\)\]/\1/p' "$f" | tr ',' '\n'
    } | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr 'A-Z' 'a-z' | grep -v '^$' | sort -u |
      while IFS= read -r n; do printf '%s\t%s\n' "$n" "$f"; done
  done | sort | awk -F'\t' '
    $1 == name { files = files "、" $2; n++; next }
    { if (n > 1) printf "  · 「%s」—— %s\n", name, files; name = $1; files = $2; n = 1 }
    END { if (n > 1) printf "  · 「%s」—— %s\n", name, files }'
)

[ -z "$CONFLICTS" ] && exit 0

SID=$(printf '%s' "$IN" | jq -r '.session_id // "unknown"')
D="$ROOT/.claude/.状态"; mkdir -p "$D"
ROUND="$D/$SID.名字冲突"
N=$(cat "$ROUND" 2>/dev/null || echo 0)

if [ "$N" -ge 2 ]; then          # 逃生阀：不让一条改不动的冲突把会话永久困住
  rm -f "$ROUND"
  jq -n --arg c "$CONFLICTS" '{systemMessage: ("名字冲突仍未解决，已达 2 轮上限，本次放行。但博客构建会拦住它，部署会红：\n" + $c)}'
  exit 0
fi
printf '%s\n' $((N+1)) > "$ROUND"

jq -n --arg c "$CONFLICTS" --arg round "$((N+1))" '
{
  decision: "block",
  reason: (
    "【名字冲突 · 第 " + $round + "/2 轮】同一个名字被多篇认领，收工前必须解决：\n" + $c + "\n" +
    "笔记名和 aliases 共用一张全局解析表，撞车时 [[这个名字]] 指向哪一篇是掷骰子，\n" +
    "博客构建因此直接中断（BLOG_STRICT=1 下属 fatal）。\n\n" +
    "改法：别名归**定义这个概念的那篇**，不归它的实现或实践篇。\n" +
    "同义词整组一起归位 —— 只挪一个，剩下那个仍指向另一篇，问题从「构建中断」变成「静默指错」，更糟。\n" +
    "真是两篇讲同一件事，那就走「合并」流程。\n\n" +
    "改完直接结束本轮，本关卡会重新扫描复查。"
  )
}'
exit 0
