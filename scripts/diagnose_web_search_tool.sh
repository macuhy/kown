#!/usr/bin/env bash
# 诊断:claude-opus-4-7 开「带工具」请求是否回空,以及是否与工具名有关。
# 无第三方依赖(只用 curl;有 jq 则额外打印摘要,没有也不影响)。
#
# 用法:
#   ANTHROPIC_API_KEY=sk-...  bash scripts/diagnose_web_search_tool.sh
# 走中转代理时(地址不要带 /v1/messages):
#   ANTHROPIC_API_KEY=sk-...  ANTHROPIC_BASE_URL=https://你的中转域名  bash scripts/diagnose_web_search_tool.sh
set -u

BASE="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
URL="${BASE%/}/v1/messages"
MODEL="${MODEL:-claude-opus-4-7}"
KEY="${ANTHROPIC_API_KEY:?请先 export ANTHROPIC_API_KEY=你的key}"

echo "模型: $MODEL"
echo "端点: $URL"
echo

# 与 Kown 一致的工具 schema,只有 name 不同。
tool_json() {  # $1 = 工具名
  cat <<JSON
{"name":"$1","description":"Search the public web with Firecrawl and return up-to-date results (title, URL, snippet).","input_schema":{"type":"object","properties":{"query":{"type":"string","description":"The search query."},"limit":{"type":"integer","description":"Max results (1-100)."}},"required":["query"]}}
JSON
}

run() {  # $1=标签  $2=tools 数组JSON(空串=不带 tools)
  local label="$1" tools="$2" body
  if [ -n "$tools" ]; then
    body="{\"model\":\"$MODEL\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"tools\":$tools}"
  else
    body="{\"model\":\"$MODEL\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}"
  fi
  echo "===================================================================="
  echo "[$label]"
  echo "--- HTTP 状态 + 原始返回(截断 1500 字) ---"
  # -w 末尾打印 HTTP 码;-s 静默;响应体直接给你看
  curl -s -w $'\n<<HTTP_CODE:%{http_code}>>\n' "$URL" \
    -H "content-type: application/json" \
    -H "x-api-key: $KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "$body" | head -c 1500
  echo
}

run "A · 带自定义工具,名为 web_search(疑似撞内置名)" "[$(tool_json web_search)]"
run "B · 同一工具,改名 firecrawl_web_search"          "[$(tool_json firecrawl_web_search)]"
run "C · 不带任何工具(对照组)"                         ""

echo "===================================================================="
echo "怎么读:"
echo "  · HTTP 不是 200 / 出现 \"type\":\"error\"  → 是报错(看 message),不是单纯空"
echo "  · HTTP 200 且 content 里有 text 块         → 正常出字"
echo "  · HTTP 200 但 content 为 [] / 只有 thinking → 空响应(本次要查的现象)"
echo "判定:"
echo "  · A 空、B 有字           → 撞名是真因,改名能修(你的 app 需更到带新名的版本)"
echo "  · A 空、B 也空、C 正常   → 与工具名无关:这条线路/模型对『带工具』请求回空(多半是中转不支持 tool use)"
echo "  · 三个都正常             → 裸 API 复现不出,问题在 app 多带的 system/cache_control/多轮循环"
