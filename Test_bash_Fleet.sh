#!/usr/bin/env bash
# =====================================================================================
# 🚀 Ubuntu 24.04 - 一鍵安裝/檢查 Fleet Server(HTTPS) 與 Elastic Agent（docker-elk 網路）
# - 建立/檢查自簽 TLS 憑證（可選）
# - 以 HTTPS :8220 啟動 fleet-server（TLS 強制）
# - 以 Kibana API 初始化 Fleet / 建立 Policy / Enrollment Token / 設定 Fleet Server Hosts
# - 啟動一般 Agent 並信任自簽 CA
# - 可重複執行（idempotent），並輸出清楚檢查項目與紀錄
# Author: docker-elk helper
# =====================================================================================
set -Eeuo pipefail

# -------- 可用環境變數（可覆寫） --------
ELK_VERSION="${ELK_VERSION:-9.0.3}"

# ES/Kibana 端點
ES_URL="${ES_URL:-http://localhost:9200}"
KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"

# docker-elk 預設網路
DOCKER_NETWORK="${DOCKER_NETWORK:-docker-elk_elk}"

# Fleet Server 參數（HTTPS）
FLEET_SERVER_NAME="${FLEET_SERVER_NAME:-fleet-server}"
FLEET_HOSTNAME_FOR_CERT="${FLEET_HOSTNAME_FOR_CERT:-fleet-server}"   # 憑證 CN/SAN 主機名
FLEET_BIND_IP="${FLEET_BIND_IP:-0.0.0.0}"
FLEET_PORT="${FLEET_PORT:-8220}"
FLEET_URL="https://${FLEET_HOSTNAME_FOR_CERT}:${FLEET_PORT}"          # Kibana/Fleet/Agent 看到的 Fleet URL（HTTPS）

# 憑證路徑（會掛載到容器 /certs）
FLEET_CERT_DIR="${FLEET_CERT_DIR:-$HOME/fleet-certs}"
FLEET_CA_FILE="${FLEET_CA_FILE:-${FLEET_CERT_DIR}/ca.crt}"
FLEET_CA_KEY="${FLEET_CA_KEY:-${FLEET_CERT_DIR}/ca.key}"
FLEET_CERT_FILE="${FLEET_CERT_FILE:-${FLEET_CERT_DIR}/fleet-server.crt}"
FLEET_CERT_KEY="${FLEET_CERT_KEY:-${FLEET_CERT_DIR}/fleet-server.key}"
GENERATE_SELF_SIGNED="${GENERATE_SELF_SIGNED:-1}" # 1=自動產生自簽CA與Server憑證；0=使用既有憑證

# Policy 名稱（若不存在會自動建立）
FLEET_SERVER_POLICY_NAME="${FLEET_SERVER_POLICY_NAME:-Fleet Server Policy (HTTPS)}"
AGENT_POLICY_NAME="${AGENT_POLICY_NAME:-Default policy (HTTPS)}"

# 容器控制
AGENT_NAME="${AGENT_NAME:-elastic-agent-1}"
RECREATE="${RECREATE:-0}"  # 1=若存在則重建容器

# 日誌
LOG_FILE="install_fleet_https_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# -------- 小工具 --------
need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ 缺少命令：$1"; exit 1; }; }
json() { jq -r "$1" 2>/dev/null || true; }
retry() { # retry <times> <sleep> <cmd...>
  local -i tries=$1; shift
  local -i wait=$1; shift
  local i
  for ((i=1; i<=tries; i++)); do
    if "$@"; then return 0; fi
    echo "  ⏳ 第 $i/$tries 次嘗試失敗，${wait}s 後重試..."
    sleep "$wait"
  done
  return 1
}
docker_exists() { docker ps -a --format '{{.Names}}' | grep -Fxq "$1"; }
docker_running() { docker ps --format '{{.Names}}' | grep -Fxq "$1"; }

kbn_api() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sS -u "elastic:${ELASTIC_PASSWORD}" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -X "${method}" "${KIBANA_URL}${path}" "$@"
}

# -------- 機器/參數檢查 --------
echo "=============================================="
echo "🧪 Fleet Server(HTTPS) 安裝/檢查 開始 $(date)"
echo "📂 Log：$LOG_FILE"
echo "=============================================="

need docker
need jq
need curl
need openssl

if [[ -z "${ELASTIC_PASSWORD:-}" ]]; then
  read -rp "🔐 請輸入 elastic 使用者密碼: " -s ELASTIC_PASSWORD; echo
fi

echo "🔎 參數確認："
cat <<EOF
  ELK_VERSION              = $ELK_VERSION
  ES_URL                   = $ES_URL
  KIBANA_URL               = $KIBANA_URL
  DOCKER_NETWORK           = $DOCKER_NETWORK

  FLEET_SERVER_NAME        = $FLEET_SERVER_NAME
  FLEET_HOSTNAME_FOR_CERT  = $FLEET_HOSTNAME_FOR_CERT
  FLEET_BIND_IP            = $FLEET_BIND_IP
  FLEET_PORT               = $FLEET_PORT
  FLEET_URL                = $FLEET_URL

  FLEET_CERT_DIR           = $FLEET_CERT_DIR
  FLEET_CA_FILE            = $FLEET_CA_FILE
  FLEET_CERT_FILE          = $FLEET_CERT_FILE
  GENERATE_SELF_SIGNED     = $GENERATE_SELF_SIGNED

  FLEET_SERVER_POLICY_NAME = $FLEET_SERVER_POLICY_NAME
  AGENT_POLICY_NAME        = $AGENT_POLICY_NAME
  AGENT_NAME               = $AGENT_NAME
  RECREATE                 = $RECREATE
EOF

# -------- Docker Network --------
if ! docker network ls --format '{{.Name}}' | grep -Fxq "$DOCKER_NETWORK"; then
  echo "🌐 建立 Docker 網路：$DOCKER_NETWORK"
  docker network create "$DOCKER_NETWORK"
else
  echo "✅ Docker 網路存在：$DOCKER_NETWORK"
fi

# -------- ES 健康 --------
echo "🩺 檢查 Elasticsearch..."
if ! retry 10 3 curl -sS -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL}"; then
  echo "❌ 無法連線 Elasticsearch：$ES_URL"
  exit 2
fi
ES_INFO="$(curl -sS -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL}")"
echo "  版本：$(echo "$ES_INFO" | json '.version.number')"
echo "  節點：$(echo "$ES_INFO" | json '.name')"

# -------- Kibana 狀態 --------
echo "🩺 檢查 Kibana..."
KBN_STATUS="$(retry 20 3 curl -sS "${KIBANA_URL}/api/status" | jq -r '.status.overall.level' || true)"
if [[ "$KBN_STATUS" != "available" ]]; then
  echo "⚠️ Kibana 狀態：$KBN_STATUS（將繼續嘗試 Fleet 初始化）"
else
  echo "✅ Kibana 可用"
fi

# -------- 憑證（自簽或沿用）--------
echo "🔐 檢查/準備 Fleet Server 憑證..."
mkdir -p "$FLEET_CERT_DIR"
if [[ "$GENERATE_SELF_SIGNED" == "1" ]]; then
  # 產生自簽 CA 與伺服器憑證（覆寫同名檔案）
  echo "  ➤ 產生自簽 CA 與 Server 憑證（將覆寫現有檔案）"
  # CA
  openssl req -x509 -new -nodes -sha256 -days 3650 \
    -subj "/C=TW/O=Local CA/CN=elastic-fleet-ca" \
    -newkey rsa:4096 -keyout "$FLEET_CA_KEY" -out "$FLEET_CA_FILE"
  # 伺服器 CSR 與金鑰
  SERVER_KEY="$FLEET_CERT_KEY"
  SERVER_CSR="${FLEET_CERT_DIR}/fleet-server.csr"
  SERVER_CRT="$FLEET_CERT_FILE"

  cat > "${FLEET_CERT_DIR}/fleet-openssl.cnf" <<CONF
[req]
distinguished_name=req
req_extensions = v3_req
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = ${FLEET_HOSTNAME_FOR_CERT}
DNS.2 = localhost
IP.1  = 127.0.0.1
CONF

  openssl req -new -newkey rsa:4096 -nodes \
    -keyout "$SERVER_KEY" \
    -subj "/C=TW/O=Elastic/CN=${FLEET_HOSTNAME_FOR_CERT}" \
    -out "$SERVER_CSR" \
    -config "${FLEET_CERT_DIR}/fleet-openssl.cnf"

  openssl x509 -req -in "$SERVER_CSR" -CA "$FLEET_CA_FILE" -CAkey "$FLEET_CA_KEY" \
    -CAcreateserial -out "$SERVER_CRT" -days 1095 -sha256 \
    -extensions v3_req -extfile "${FLEET_CERT_DIR}/fleet-openssl.cnf"

  rm -f "$SERVER_CSR" "${FLEET_CERT_DIR}/fleet-openssl.srl" || true
fi

# 權限建議
chmod 644 "$FLEET_CA_FILE" "$FLEET_CERT_FILE" || true
chmod 600 "${FLEET_CERT_KEY}" || true

echo "  CA    ：$FLEET_CA_FILE"
echo "  Cert  ：$FLEET_CERT_FILE"
echo "  Key   ：$FLEET_CERT_KEY"

# -------- Fleet 初始化 --------
echo "⚙️ Fleet 初始化（可重複執行）..."
FLEET_STATUS_JSON="$(kbn_api GET "/api/fleet/status")"
FLEET_IS_INITIALIZED="$(echo "$FLEET_STATUS_JSON" | json '.isInitialized')"
echo "  isInitialized: $FLEET_IS_INITIALIZED"
if [[ "$FLEET_IS_INITIALIZED" != "true" ]]; then
  echo "  ➤ 執行 /api/fleet/setup"
  kbn_api POST "/api/fleet/setup" >/dev/null || true
  sleep 2
fi

# -------- 取得/建立 Policy --------
get_policy_id_by_name() {
  local name="$1"
  kbn_api GET "/api/fleet/agent_policies?perPage=1000" \
    | jq -r --arg n "$name" '.items[] | select(.name==$n) | .id' | head -n1
}
create_policy() { # <name> <desc> <is_default>
  local name="$1" desc="$2" is_default="${3:-false}"
  kbn_api POST "/api/fleet/agent_policies" \
    --data "{\"name\":\"$name\",\"description\":\"$desc\",\"namespace\":\"default\",\"is_default\":$is_default}" \
    | json '.item.id'
}
get_or_create_policy() {
  local name="$1" desc="$2" is_default="${3:-false}"
  local id; id="$(get_policy_id_by_name "$name")"
  if [[ -n "$id" ]]; then echo "$id"; return 0; fi
  echo "  ➤ 建立 Policy：$name"
  create_policy "$name" "$desc" "$is_default"
}

echo "📋 準備 Policies..."
FLEET_SERVER_POLICY_ID="$(get_or_create_policy "$FLEET_SERVER_POLICY_NAME" "Policy for HTTPS Fleet Server" false)"
AGENT_POLICY_ID="$(get_or_create_policy "$AGENT_POLICY_NAME" "Default policy for HTTPS agents" true)"
echo "  Fleet Server Policy ID: $FLEET_SERVER_POLICY_ID"
echo "  Agent Policy ID       : $AGENT_POLICY_ID"

# -------- Fleet Server Hosts（寫入 HTTPS URL）--------
echo "🌍 設定 Fleet Server Hosts（HTTPS）..."
# 讀取現有 hosts
EXISTING_HOST_ID="$(kbn_api GET "/api/fleet/fleet_server_hosts" | jq -r --arg u "$FLEET_URL" '.items[] | select(.host_urls[]==$u) | .id' | head -n1)"
if [[ -z "$EXISTING_HOST_ID" ]]; then
  echo "  ➤ 新增 Fleet Server Host: $FLEET_URL"
  kbn_api POST "/api/fleet/fleet_server_hosts" \
    --data "{\"name\":\"https-fleet\",\"host_urls\":[\"${FLEET_URL}\"]}" >/dev/null
else
  echo "  ✅ 已存在 Fleet Server Host: $FLEET_URL"
fi

# -------- Enrollment Tokens --------
get_enroll_key_for_policy() { # <policy_id>
  local pid="$1"
  kbn_api GET "/api/fleet/enrollment-api-keys?perPage=1000" \
    | jq -r --arg pid "$pid" '.items[] | select(.policy_id==$pid and .active==true) | .api_key' | head -n1
}
create_enroll_key_for_policy() { # <policy_id> <name>
  local pid="$1" name="$2"
  kbn_api POST "/api/fleet/enrollment-api-keys" \
    --data "{\"policy_id\":\"$pid\",\"name\":\"$name\"}" \
    | json '.item.api_key'
}
ensure_enroll_key() { # <policy_id> <name>
  local pid="$1" name="$2" key
  key="$(get_enroll_key_for_policy "$pid")"
  if [[ -z "$key" || "$key" == "null" ]]; then
    echo "  ➤ 建立 Enrollment Token：$name"
    key="$(create_enroll_key_for_policy "$pid" "$name")"
  fi
  echo "$key"
}

echo "🔑 取得/建立 Enrollment Token..."
FLEET_SERVER_ENROLL_TOKEN="$(ensure_enroll_key "$FLEET_SERVER_POLICY_ID" "fleet-server-enroll-https")"
AGENT_ENROLL_TOKEN="$(ensure_enroll_key "$AGENT_POLICY_ID" "agent-enroll-https")"
[[ -n "$FLEET_SERVER_ENROLL_TOKEN" && -n "$AGENT_ENROLL_TOKEN" ]] || { echo "❌ 無法取得 Enrollment Token"; exit 3; }

# -------- 啟動 Fleet Server (HTTPS) 容器 --------
start_fleet_server() {
  echo "🚀 啟動 Fleet Server(HTTPS) 容器：$FLEET_SERVER_NAME"
  docker run -d --name "$FLEET_SERVER_NAME" --restart=unless-stopped \
    --network "$DOCKER_NETWORK" -p "${FLEET_PORT}:${FLEET_PORT}" \
    -v "${FLEET_CERT_DIR}:/certs:ro" \
    -e FLEET_SERVER_ENABLE=1 \
    -e FLEET_ENROLL=1 \
    -e FLEET_URL="$FLEET_URL" \
    -e FLEET_SERVER_POLICY_ID="$FLEET_SERVER_POLICY_ID" \
    -e FLEET_ENROLLMENT_TOKEN="$FLEET_SERVER_ENROLL_TOKEN" \
    -e FLEET_SERVER_HOST="$FLEET_BIND_IP" \
    -e FLEET_SERVER_PORT="$FLEET_PORT" \
    -e FLEET_SERVER_CERT="/certs/$(basename "$FLEET_CERT_FILE")" \
    -e FLEET_SERVER_CERT_KEY="/certs/$(basename "$FLEET_CERT_KEY")" \
    -e KIBANA_FLEET_SETUP=1 \
    -e KIBANA_HOST="$KIBANA_URL" \
    -e KIBANA_USERNAME="elastic" \
    -e KIBANA_PASSWORD="$ELASTIC_PASSWORD" \
    docker.elastic.co/elastic-agent/elastic-agent:"$ELK_VERSION"
}

if docker_exists "$FLEET_SERVER_NAME"; then
  if [[ "$RECREATE" == "1" ]]; then
    echo "♻️ 重建 Fleet Server 容器：$FLEET_SERVER_NAME"
    docker rm -f "$FLEET_SERVER_NAME" || true
    start_fleet_server
  else
    echo "✅ Fleet Server 容器已存在：$FLEET_SERVER_NAME"
    if ! docker_running "$FLEET_SERVER_NAME"; then
      echo "  ➤ 啟動已存在的容器"
      docker start "$FLEET_SERVER_NAME"
    fi
  fi
else
  start_fleet_server
fi

# -------- 檢查 Fleet Server HTTPS 連通性 --------
echo "⏳ 檢查 Fleet Server HTTPS (${FLEET_URL}) ..."
# 若自簽，這裡使用 -k 忽略驗證，只檢查是否有 TLS 服務起來
retry 20 3 curl -sS -k "${FLEET_URL}" >/dev/null || true

# 以 Kibana API 檢查是否有 fleet-server agent 線上
IS_FLEET_SERVER_READY="false"
for i in {1..30}; do
  AGENTS_JSON="$(kbn_api GET "/api/fleet/agents?perPage=100&showInactive=true")"
  IS_FLEET_SERVER_READY="$(echo "$AGENTS_JSON" | jq -r '.list[] | select(.type=="fleet-server" and .active==true) | .status' | grep -Eq 'online|updating' && echo true || echo false)"
  COUNT="$(echo "$AGENTS_JSON" | jq -r '.list | length')"
  echo "  ➤ Agent 數：$COUNT；Fleet Server ready: $IS_FLEET_SERVER_READY"
  [[ "$IS_FLEET_SERVER_READY" == "true" ]] && break
  sleep 4
done

# -------- 啟動一般 Agent（信任自簽 CA）--------
start_agent() {
  echo "🚀 啟動一般 Agent 容器：$AGENT_NAME"
  docker run -d --name "$AGENT_NAME" --restart=unless-stopped \
    --network "$DOCKER_NETWORK" \
    -v "${FLEET_CERT_DIR}:/certs:ro" \
    -e FLEET_ENROLL=1 \
    -e FLEET_URL="$FLEET_URL" \
    -e FLEET_ENROLLMENT_TOKEN="$AGENT_ENROLL_TOKEN" \
    -e FLEET_CA="/certs/$(basename "$FLEET_CA_FILE")" \
    docker.elastic.co/elastic-agent/elastic-agent:"$ELK_VERSION"
}

if docker_exists "$AGENT_NAME"; then
  if [[ "$RECREATE" == "1" ]]; then
    echo "♻️ 重建 Agent 容器：$AGENT_NAME"
    docker rm -f "$AGENT_NAME" || true
    start_agent
  else
    echo "✅ Agent 容器已存在：$AGENT_NAME"
    if ! docker_running "$AGENT_NAME"; then
      echo "  ➤ 啟動已存在的容器"
      docker start "$AGENT_NAME"
    fi
  fi
else
  start_agent
fi

# -------- 最終檢查（可重複執行）--------
echo "=============================================="
echo "🔍 最終檢查（容器/狀態/Agents）"
echo "  - 容器列表"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | grep -E "^(${FLEET_SERVER_NAME}|${AGENT_NAME})\b" || true

echo "  - Fleet 狀態"
kbn_api GET "/api/fleet/status" | jq '{isInitialized,hasRequiredFleetServer,missingRequirements}'

echo "  - Fleet Server Hosts"
kbn_api GET "/api/fleet/fleet_server_hosts" | jq '.items[] | {name,host_urls}'

echo "  - Agents 清單（狀態/類型/主機名）"
kbn_api GET "/api/fleet/agents?perPage=100" | jq -r '.list[] | "\(.status)\t\(.type)\t\(.local_metadata.host.hostname)"'

echo "=============================================="
echo "🎯 判讀重點："
echo "  1) hasRequiredFleetServer=true 代表 Fleet Server 連線正常。"
echo "  2) Agents 清單看到一筆 type=fleet-server 且狀態 online/updating 即成功。"
echo "  3) 客戶端 Agent 連線自簽 HTTPS 需信任 CA（本腳本以 FLEET_CA 掛載給 Agent）。"
echo "  4) 如使用自己的正式憑證：將 GENERATE_SELF_SIGNED=0 並把檔案放到 FLEET_CERT_DIR。"
echo "  5) 需要重建容器：RECREATE=1 $0"
echo "📜 完整日誌：$LOG_FILE"
echo "=============================================="
