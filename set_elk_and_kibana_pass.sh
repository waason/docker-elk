#!/usr/bin/env bash
# =========================================================
# docker-elk 密碼設定工具（自訂密碼版）
# 會把 elastic 和 kibana_system 的密碼改成指定值，並同步 .env
# 用法（非互動）：
#   ./set_elk_passwords.sh --elastic NEW_ELASTIC --kibana NEW_KIBANA [--current CUR_ELASTIC]
# 用法（互動）：
#   ./set_elk_passwords.sh
# 需求：docker compose、curl
# =========================================================
set -euo pipefail

# --- 參數解析 ---------------------------------------------------------------
NEW_ELASTIC=""
NEW_KIBANA=""
CUR_ELASTIC="${CUR_ELASTIC:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --elastic) NEW_ELASTIC="$2"; shift 2;;
    --kibana)  NEW_KIBANA="$2";  shift 2;;
    --current) CUR_ELASTIC="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 --elastic <NEW_ELASTIC> --kibana <NEW_KIBANA> [--current <CUR_ELASTIC>]"
      exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# --- 前置檢查 ---------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if [[ ! -f docker-compose.yml ]]; then
  echo "❌ 請在 docker-elk 專案根目錄執行（找不到 docker-compose.yml）"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo "❌ 未安裝 docker"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "❌ 未安裝 curl"
  exit 1
fi

# --- 讀取 .env 取得目前密碼（若有） ------------------------------------------
if [[ -f .env ]]; then
  # shellcheck disable=SC2046
  export $(grep -E '^(ELASTIC_PASSWORD|KIBANA_SYSTEM_PASSWORD)=' .env | xargs -d '\n' -I {} echo {})
  CUR_ELASTIC="${CUR_ELASTIC:-${ELASTIC_PASSWORD:-}}"
fi

# --- 若未提供新密碼，改為互動輸入 -------------------------------------------
if [[ -z "${NEW_ELASTIC}" ]]; then
  read -rsp "請輸入『elastic』新密碼: " NEW_ELASTIC; echo
fi
if [[ -z "${NEW_KIBANA}" ]]; then
  read -rsp "請輸入『kibana_system』新密碼: " NEW_KIBANA; echo
fi
if [[ -z "${CUR_ELASTIC}" ]]; then
  read -rsp "請輸入目前『elastic』密碼（若剛裝好/已在 .env，直接 Enter 可略過）: " CUR_ELASTIC || true; echo
  CUR_ELASTIC="${CUR_ELASTIC:-${ELASTIC_PASSWORD:-}}"
fi

# --- 啟動並等待 Elasticsearch ------------------------------------------------
echo "⚙️  確認 Elasticsearch 容器..."
if ! docker compose ps elasticsearch | grep -qi "running"; then
  docker compose up -d elasticsearch
fi

ES_URL="${ES_URL:-http://127.0.0.1:9200}"
echo "⏳ 等待 Elasticsearch 就緒：$ES_URL"
for i in {1..60}; do
  if [[ -n "${CUR_ELASTIC}" ]]; then
    if curl -s -k -u "elastic:${CUR_ELASTIC}" "${ES_URL}" >/dev/null; then break; fi
  else
    # 若尚未啟用安全，仍可無密碼回應，但 docker-elk 預設會啟用安全
    if curl -s -k "${ES_URL}" >/dev/null; then break; fi
  fi
  sleep 2
  [[ $i -eq 60 ]] && { echo "❌ 等待 Elasticsearch 超時"; exit 1; }
done
echo "✅ Elasticsearch 已回應"

# --- 變更 elastic 密碼 -------------------------------------------------------
echo "🔐 設定『elastic』新密碼..."
if [[ -z "${CUR_ELASTIC}" ]]; then
  echo "❌ 不知道目前 elastic 密碼，無法變更。請在 .env 設定 ELASTIC_PASSWORD 或用 --current 提供。"
  exit 1
fi

curl -sS -f -u "elastic:${CUR_ELASTIC}" -H "Content-Type: application/json" \
  -X POST "${ES_URL}/_security/user/elastic/_password" \
  -d "{\"password\":\"${NEW_ELASTIC}\"}" >/dev/null
echo "   ✔ 已更新 elastic 密碼"

# --- 變更 kibana_system 密碼 -------------------------------------------------
echo "🔐 設定『kibana_system』新密碼..."
curl -sS -f -u "elastic:${NEW_ELASTIC}" -H "Content-Type: application/json" \
  -X POST "${ES_URL}/_security/user/kibana_system/_password" \
  -d "{\"password\":\"${NEW_KIBANA}\"}" >/dev/null
echo "   ✔ 已更新 kibana_system 密碼"

# --- 更新 .env ---------------------------------------------------------------
echo "📝 同步 .env ..."
if [[ -f .env ]]; then
  sed -i "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=${NEW_ELASTIC}/" .env
  sed -i "s/^KIBANA_SYSTEM_PASSWORD=.*/KIBANA_SYSTEM_PASSWORD=${NEW_KIBANA}/" .env
else
  cat > .env <<EOF
ELASTIC_PASSWORD=${NEW_ELASTIC}
KIBANA_SYSTEM_PASSWORD=${NEW_KIBANA}
EOF
fi

# --- 重啟 Kibana -------------------------------------------------------------
echo "🔄 重啟 Kibana ..."
docker compose restart kibana >/dev/null

echo "=============================================="
echo "✅ 密碼已設定並同步完成！"
echo "🔑 elastic        = ${NEW_ELASTIC}"
echo "🔑 kibana_system  = ${NEW_KIBANA}"
echo "📘 請用 elastic 登入 Kibana： http://127.0.0.1:5601"
echo "=============================================="
