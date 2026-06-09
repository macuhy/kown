#!/usr/bin/env bash
# 诊断:claude-opus-4-7 是否因为自定义工具名 "web_search" 撞内置工具名而回空。
# 用法:
#   ANTHROPIC_API_KEY=sk-...  [ANTHROPIC_BASE_URL=https://api.anthropic.com]  bash scripts/diagnose_web_search_tool.sh
# 如果你用中转代理,把 ANTHROPIC_BASE_URL 设成代理地址(不带 /v1/messages 后缀)。
set -u

BASE="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
URL="${BASE%/}/v1/messages"
MODEL="${MODEL:-claude-opus-4-7}"
KEY="${ANTHROPIC_API_KEY:?请先 export ANTHROPIC_API_KEY}"

# 与 Kown 完全一致的 web_search 工具 schema,只有 name 不同。
tool_schema() {  # $1 = tool name
  cat <<JSON
{
  "name": "$1",
  "description": "Search the public web with Firecrawl and return up-to-date results (title, URL, snippet). Use this whenever the user asks about recent events.",
  "input_schema": {
    "type": "object",
    "properties": {
      "query": { "type": "string", "description": "The search query." },
      "limit": { "type": "integer", "description": "Max results (1-100)." }
    },
    "required": ["query"]
  }
}
JSON
}

run() {  # $1 = 标签   $2 = tools JSON 数组(可为空字符串表示不带 tools)
  local label="$1" tools="$2" body
  if [ -n "$tools" ]; then
    body=$(printf '{"model":"%s","max_tokens":256,"messages":[{"role":"user","content":"hello"}],"tools":%s}' "$MODEL" "$tools")
  else
    body=$(printf '{"model":"%s","max_tokens":256,"messages":[{"role":"user","content":"hello"}]}' "$MODEL")
  fi
  echo "===================================================================="
  echo "[$label]"
  resp=$(curl -s "$URL" \
    -H "content-type: application/json" \
    -H "x-api-key: $KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "$body")
  # 打印 stop_reason、是否有 text、是否有 tool_use、以及报错(若有)
  echo "$resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("  解析失败:", e); sys.exit()
if d.get("type") == "error":
    print("  ERROR:", d.get("error", {}).get("type"), "-", d.get("error", {}).get("message"))
    sys.exit()
blocks = d.get("content", [])
texts = [b.get("text","") for b in blocks if b.get("type")=="text"]
tools = [b.get("name") for b in blocks if b.get("type")=="tool_use"]
print("  stop_reason:", d.get("stop_reason"))
print("  text:", repr("".join(texts)[:120]) if texts else "(无 text)")
print("  tool_use:", tools if tools else "(无)")
print("  >>> 判定:", "空响应(无 text 无 tool_use)" if not texts and not tools else "正常")
'
}

echo "模型: $MODEL   端点: $URL"
run "A · 带自定义工具,名为 web_search(疑似撞名)" "[$(tool_schema web_search)]"
run "B · 同一工具,改名 firecrawl_web_search"        "[$(tool_schema firecrawl_web_search)]"
run "C · 不带任何工具(对照组)"                       ""
echo "===================================================================="
echo "若 A=空、B/C=正常 → 撞名实锤,改名即修。"
