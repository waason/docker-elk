cat > elk-doctor.sh <<'EOF'
#!/usr/bin/env bash
# docker-elk 健診工具（menu 版）
# 適用：Ubuntu 24.04 + docker-elk 預設佈署
# 作者：docker-elk 顧問

set -o pipefail
set -u

# ====== 基本參數 ======
ES_URL=${ES_URL:-"http://localhost:9200"}
KBN_URL=${KBN_URL:-"http://localhost:5601"}
LS_URL=${LS_URL:-"http://localhost:9600"}
DOCKER_NETWORK=${DOCKER_NETWORK:-"docker-elk_elk"}
PROJECT_DIR=${PROJECT_DIR:-"/home/cape/docker-elk"}

# 顏色
C_RESET="\033[0m"; C_Y="\033[1;33m"; C_G="\033[1;32m"; C_R="\033[1;31m"; C_B="\033[1;34m"

need() { command -v "$1" >/dev/null 2>&1 || { echo -e "${C_R}缺少指令：$1${C_RESET}"; MISSING=1; }; }

# ====== 先決條件檢查 ======
precheck() {
  MISSING=0
  need curl; need jq; need docker
  if [ "${MISSING:-0}" = "1" ]; then
    echo -e "${C_Y}請先安裝必要套件：sudo apt-get update && sudo apt-get install -y curl jq docker.io${C_RESET}"
    exit 1
  fi

  if [ -z "${ELASTIC_PASSWORD:-}" ]; then
    read -s -p "請輸入 ELASTIC_PASSWORD（elastic 超級使用者）： " ELASTIC_PASSWORD
    echo
  fi
  AUTH_ES=(-u "elastic:${ELASTIC_PASSWORD}")
  AUTH_KBN=(-u "elastic:${ELASTIC_PASSWORD}" -H "kbn-xsrf: true")
}

# ====== 共用 ======
ok_or_not() {
  if [ "$1" -eq 0 ]; then echo -e "${C_G}OK${C_RESET}"; else echo -e "${C_R}NOT OK${C_RESET}"; fi
}

hr() { printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' -; }

# ====== 1) 服務健康 ======
svc_health() {
  echo -e "${C_B}== Docker 容器與 Port ==${C_RESET}"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

  echo
  echo -e "${C_B}== Docker IP（Network: ${DOCKER_NETWORK}）==${C_RESET}"
  docker inspect -f '{{.Name}} -> {{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $(docker ps -q) | sed 's#^/##'

  echo
  echo -e "${C_B}== Docker 即時資源（一次性快照）==${C_RESET}"
  docker stats --no-stream

  echo
  echo -e "${C_B}== Elasticsearch 節點狀態 ==${C_RESET}"
  curl -s "${ES_URL}/_cluster/health" "${AUTH_ES[@]}" | jq

  echo
  echo -e "${C_B}== Elasticsearch 節點清單 ==${C_RESET}"
  curl -s "${ES_URL}/_cat/nodes?v&h=ip,name,version,heap.percent,ram.percent,cpu,load_1m,node.role" "${AUTH_ES[@]}"

  echo
  echo -e "${C_B}== Kibana 狀態 ==${C_RESET}"
  curl -s "${KBN_URL}/api/status" "${AUTH_KBN[@]}" | jq '.status.overall.state,.metrics.last_updated' 2>/dev/null || true

  echo
  echo -e "${C_B}== Logstash Node Info ==${C_RESET}"
  curl -s "${LS_URL}/" | jq 2>/dev/null || curl -s "${LS_URL}/" || true

  echo
  echo -e "${C_Y}[判讀]${C_RESET} cluster health 應為 ${C_G}green${C_RESET}（或 yellow）；Kibana 狀態應非 red；Logstash 回應應含版本與管線資訊。"
}

# ====== 2) ES 索引/文件/管線 ======
es_indices() {
  echo -e "${C_B}== Top 15 索引（依文件數）==${C_RESET}"
  curl -s "${ES_URL}/_cat/indices?h=index,docs.count,store.size,health,status&s=docs.count:desc" "${AUTH_ES[@]}" | head -n 16 | column -t

  echo
  echo -e "${C_B}== 別名與 Data Streams（前 50）==${C_RESET}"
  echo "[aliases]"
  curl -s "${ES_URL}/_cat/aliases?v" "${AUTH_ES[@]}" | head -n 50
  echo "[data_streams]"
  curl -s "${ES_URL}/_cat/data_streams?v" "${AUTH_ES[@]}" | head -n 50

  echo
  echo -e "${C_B}== Ingest Pipelines（前 50）==${C_RESET}"
  curl -s "${ES_URL}/_cat/ingest/pipeline?v" "${AUTH_ES[@]}" | head -n 50

  echo
  echo -e "${C_B}== 索引寫入速度（近1分鐘）==${C_RESET}"
  curl -s "${ES_URL}/_nodes/stats/indices/indexing?level=indices" "${AUTH_ES[@]}" \
    | jq '[.. | objects | select(has("indexing")) | {index: .index, rate_1m: (.indexing.index_total // 0)}] | sort_by(.rate_1m) | reverse | .[:15]'

  echo
  echo -e "${C_Y}[判讀]${C_RESET} 觀察資料流（logs-*/metrics-*）與 ingest pipelines 是否存在；文件數是否持續成長代表有資料進入。"
}

# ====== 3) Kibana/加密金鑰 ======
kbn_keys() {
  echo -e "${C_B}== Kibana 狀態 ==${C_RESET}"
  curl -s "${KBN_URL}/api/status" "${AUTH_KBN[@]}" | jq '.status.overall.state, .metrics.last_updated'

  echo
  echo -e "${C_B}== Encrypted Saved Objects 狀態 ==${C_RESET}"
  curl -s "${KBN_URL}/api/encrypted_saved_objects/_status" "${AUTH_KBN[@]}" | jq

  echo
  echo -e "${C_Y}[判讀]${C_RESET} is_using_ephemeral_encryption_key 應為 ${C_G}false${C_RESET}。若為 true，代表未設定永久金鑰，重啟有風險。"
}

# ====== 4) Fleet 套件 / Policies / Agents ======
fleet_info() {
  echo -e "${C_B}== Fleet 初始化 ==${C_RESET}"
  curl -s "${KBN_URL}/api/fleet/setup" "${AUTH_KBN[@]}" | jq

  echo
  echo -e "${C_B}== 已安裝 Integrations（前 50）==${C_RESET}"
  curl -s "${KBN_URL}/api/fleet/epm/packages?prerelease=true" "${AUTH_KBN[@]}" \
    | jq '.items[] | select(.status=="installed") | {name,version}' | head -n 100

  echo
  echo -e "${C_B}== Agent Policies（列出名稱與附掛的套件）==${C_RESET}"
  curl -s "${KBN_URL}/api/fleet/agent_policies?full=true" "${AUTH_KBN[@]}" \
    | jq '.items[] | {id,name,package_policies: [.package_policies[].name] }'

  echo
  echo -e "${C_B}== Agents 狀態（前 50）==${C_RESET}"
  curl -s "${KBN_URL}/api/fleet/agents?perPage=50&page=1" "${AUTH_KBN[@]}" \
    | jq '.list[] | {id: .id, policy: .policy_id, status: .status, last_checkin: .last_checkin, local_metadata: {host: .local_metadata.host.hostname}}'

  echo
  echo -e "${C_Y}[判讀]${C_RESET} isInitialized 應為 true；常見套件（system/docker/apm/elastic_agent/fleet_server）應為 installed；Agents 應為 online。"
}

# ====== 5) Logstash API ======
ls_api() {
  echo -e "${C_B}== Logstash Main Info ==${C_RESET}"
  curl -s "${LS_URL}/" | jq

  echo
  echo -e "${C_B}== Logstash Pipelines ==${C_RESET}"
  curl -s "${LS_URL}/_node/pipelines" | jq '.pipelines | keys'

  echo
  echo -e "${C_B}== Logstash /_node/stats（摘要）==${C_RESET}"
  curl -s "${LS_URL}/_node/stats" | jq '{events: .events, jvm: .jvm.mem, pipelines: (.pipelines | keys)}'

  echo
  echo -e "${C_Y}[判讀]${C_RESET} events.in / events.out 持續變動代表有資料流過；pipelines 應出現你配置的 id。"
}

# ====== 6) 追查各容器 Log ======
logs_menu() {
  echo -n "請輸入要檢視的容器（elasticsearch/kibana/logstash/elastic-agent/fleet-server/all）[all]: "
  read target; target=${target:-all}
  echo -n "請輸入時間範圍（--since 參數，例：30m, 2h, 1d）[30m]: "
  read since; since=${since:-30m}
  echo -n "是否要關鍵字過濾（空白代表不過濾）: "
  read keyword

  case "$target" in
    elasticsearch|kibana|logstash|elastic-agent|fleet-server)
      containers=$(docker ps --format '{{.Names}}' | grep -E "$target" || true)
      ;;
    all|*)
      containers=$(docker ps --format '{{.Names}}')
      ;;
  esac

  for c in $containers; do
    echo; hr
    echo -e "${C_B}== $c logs（since ${since}）==${C_RESET}"
    if [ -n "$keyword" ]; then
      docker logs --since="$since" "$c" 2>&1 | grep -i --color=always "$keyword" || true
    else
      docker logs --since="$since" "$c" 2>&1 | tail -n 200
    fi
  done

  echo
  echo -e "${C_Y}[判讀]${C_RESET} 常見關鍵字：error|exception|authentication|fleet|pipeline|deprecated。可重複執行並調整 since/keyword。"
}

# ====== 7) 測試寫入（建立測試索引） ======
es_write_test() {
  TS=$(date +%Y%m%d-%H%M%S)
  IDX=".elk_doctor_test-${TS}"
  echo -e "${C_B}== 建立索引：${IDX} ==${C_RESET}"
  curl -s -X PUT "${ES_URL}/${IDX}" "${AUTH_ES[@]}" -H 'Content-Type: application/json' -d '{
    "mappings": { "properties": {
      "host": {"type":"keyword"},
      "msg": {"type":"text"},
      "@timestamp": {"type":"date"}
    }}
  }' | jq

  echo
  echo -e "${C_B}== 寫入文件 ==${C_RESET}"
  curl -s -X POST "${ES_URL}/${IDX}/_doc" "${AUTH_ES[@]}" -H 'Content-Type: application/json' -d "{
    \"host\": \"elk-doctor\",
    \"msg\": \"hello from elk-doctor\",
    \"@timestamp\": \"$(date -Iseconds)\"
  }" | jq

  echo
  sleep 1
  echo -e "${C_B}== 驗證文件數 ==${C_RESET}"
  curl -s "${ES_URL}/${IDX}/_count" "${AUTH_ES[@]}" | jq

  echo
  echo -e "${C_Y}[判讀]${C_RESET} _count >= 1 代表可寫入；若失敗，檢查身分驗證與索引封鎖（read-only）或磁碟水位。"
}

# ====== 8) Docker 網路 ======
net_inspect() {
  echo -e "${C_B}== 檢視 Docker Network: ${DOCKER_NETWORK} ==${C_RESET}"
  docker network inspect "${DOCKER_NETWORK}" | jq '.[0] | {Name, Driver, Subnet: .IPAM.Config[0].Subnet, Containers: (.Containers|keys)}'
  echo
  echo -e "${C_Y}[判讀]${C_RESET} 確認所有容器都在該網路中；子網無衝突；排查跨容器 DNS（用容器名互連）。"
}

# ====== 主選單 ======
menu() {
  clear
  echo -e "${C_G}docker-elk 健診工具${C_RESET}  @ $(date)"
  echo "ES: ${ES_URL} | Kibana: ${KBN_URL} | Logstash: ${LS_URL} | Network: ${DOCKER_NETWORK}"
  hr
  cat <<MENU
1) 服務健康（容器/Port/資源/ES/KBN/LS）
2) ES 索引 / 文件 / 管線
3) Kibana 狀態與加密金鑰
4) Fleet：套件 / Policies / Agents
5) Logstash API 狀態
6) 追查容器 Log（可篩選）
7) 測試寫入（建立測試索引與文件）
8) Docker 網路檢視（${DOCKER_NETWORK}）
9) 退出
MENU
  echo -n "請選擇："; read choice
  case "$choice" in
    1) svc_health; read -p "按 Enter 返回選單…" _ ;;
    2) es_indices; read -p "按 Enter 返回選單…" _ ;;
    3) kbn_keys; read -p "按 Enter 返回選單…" _ ;;
    4) fleet_info; read -p "按 Enter 返回選單…" _ ;;
    5) ls_api; read -p "按 Enter 返回選單…" _ ;;
    6) logs_menu; read -p "按 Enter 返回選單…" _ ;;
    7) es_write_test; read -p "按 Enter 返回選單…" _ ;;
    8) net_inspect; read -p "按 Enter 返回選單…" _ ;;
    9) exit 0 ;;
    *) echo "無效選項"; sleep 1 ;;
  esac
}

precheck
while true; do menu; done
EOF

chmod +x elk-doctor.sh
echo -e "\n已建立：$(pwd)/elk-doctor.sh"
