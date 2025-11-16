#!/usr/bin/env bash
# =========================================================
# 🚀 Ubuntu 24.04 - Docker + docker-elk 一鍵安裝/啟動腳本（含離線 Elastic Agent 下載）
# Author: waason (revised)
# Modified: 預設版本 & 離線 Agent 固定為 9.2.0，不再自動偵測最新版本
# Added: sudo usermod -aG docker $USER + newgrp docker
# =========================================================
set -Eeuo pipefail

LOG_FILE="install_docker_elk_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "=============================================="
echo "🐳 Docker + docker-elk 安裝啟動腳本開始（預設 9.2.0，含離線 Agent）"
echo "📅 $(date)"
echo "📂 Log 檔案：$LOG_FILE"
echo "=============================================="

wait_for_apt_unlock() {
  echo "⏳ 等待 apt/dpkg 解除鎖定..."
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "⚠️ 其他 apt 進程執行中，稍後重試..."
    sleep 5
  done
}

in_group() {
  id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

pause_dot() {
  for i in {1..3}; do printf "."; sleep 0.3; done; echo
}

# ----------- 工具安裝 -----------
wait_for_apt_unlock
echo "📦 更新系統套件（確保 curl/jq 可用）..."
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release jq

# ----------- 固定預設 Elastic Stack 版本 -----------
DEFAULT_ELK="9.2.0"
echo "🔢 Elastic Stack 預設版本：${DEFAULT_ELK}"
read -rp "若要使用其他版本請輸入（直接 Enter 採用預設 ${DEFAULT_ELK}）： " ELK_VER_IN
ELK_VER="${ELK_VER_IN:-$DEFAULT_ELK}"
echo "✅ 本次將使用 Elastic Stack 版本：${ELK_VER}"

# ----------- 密碼互動 -----------
echo -n "🔐 請輸入 Elasticsearch『elastic』使用者密碼： "
read -rs ELASTIC_PASSWORD; echo
echo -n "🔐 請輸入 Kibana『kibana_system』使用者密碼（可與上面相同）： "
read -rs KIBANA_PASSWORD; echo

# ----------- 安裝 Docker -----------
if ! command -v docker >/dev/null 2>&1; then
  echo "🔑 安裝 Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  wait_for_apt_unlock
  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "✅ Docker 已安裝"
fi

# ----------- docker 群組 + newgrp -----------
if ! in_group docker; then
  echo "👤 將 $USER 加入 docker 群組..."
  sudo groupadd docker 2>/dev/null || true
  sudo usermod -aG docker "$USER" || true
  echo "🔁 立即套用群組變更： newgrp docker"
  newgrp docker <<EOF
echo "🔄 已進入 docker 群組 session"
EOF
  DOCKER="docker"
else
  DOCKER="docker"
fi
COMPOSE="$DOCKER compose"

echo "✅ Docker 版本：$($DOCKER --version)"
echo "✅ Compose 版本：$($DOCKER compose version)"

# ----------- 建立日誌資料夾 -----------
FGT_DIR="/home/cape/Documents/fortigate_logs"
EVTX_DIR="/home/cape/Documents/win_evtx_log"

echo "🗂️ 建立日誌目錄..."
sudo install -d -m 2775 -o "$USER" -g docker "$FGT_DIR" "$EVTX_DIR" || true
sudo chmod 2775 "$FGT_DIR" "$EVTX_DIR"
ls -ld "$FGT_DIR" "$EVTX_DIR"

# ----------- 進入專案 -----------
if [ -d "$HOME/docker-elk" ]; then
  cd "$HOME/docker-elk"
else
  echo "❌ 找不到 ~/docker-elk，請先 git clone"
  exit 1
fi

# ----------- 離線 Agent（9.2.0）-----------
OFFLINE_AGENT_DIR="$(pwd)/fleet-static-agent-offline"
OFFLINE_AGENT_VER="9.2.0"
OFFLINE_AGENT_TAR="${OFFLINE_AGENT_DIR}/elastic-agent-${OFFLINE_AGENT_VER}-linux-x86_64.tar.gz"
OFFLINE_AGENT_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${OFFLINE_AGENT_VER}-linux-x86_64.tar.gz"

sudo install -d -m 775 -o "$USER" -g "$USER" "$OFFLINE_AGENT_DIR"

if [[ ! -f "$OFFLINE_AGENT_TAR" ]]; then
  echo "🌐 下載離線 Elastic Agent..."
  curl -fSL "$OFFLINE_AGENT_URL" -o "$OFFLINE_AGENT_TAR" || echo "⚠️ 下載失敗"
fi

echo "📦 離線 Agent 位置： $OFFLINE_AGENT_TAR"

# ----------- 寫入 .env -----------
touch .env
sed -i '/^ELK_VERSION=/d' .env
sed -i '/^ELASTIC_VERSION=/d' .env
sed -i '/^ELASTIC_PASSWORD=/d' .env
sed -i '/^KIBANA_PASSWORD=/d' .env

{
  printf 'ELK_VERSION=%s\n' "$ELK_VER"
  printf 'ELASTIC_VERSION=%s\n' "$ELK_VER"
  printf 'ELASTIC_PASSWORD=%q\n' "$ELASTIC_PASSWORD"
  printf 'KIBANA_PASSWORD=%q\n' "$KIBANA_PASSWORD"
} >> .env

echo "✅ .env 完成"

# ----------- 修正 elastic-agent 路徑 -----------
sed -i 's#docker.elastic.co/beats/elastic-agent#docker.elastic.co/elastic-agent/elastic-agent#g' docker-compose*.yml 2>/dev/null

# ----------- 啟動服務 -----------
$COMPOSE pull
$COMPOSE up setup
$COMPOSE build
$COMPOSE up -d

$COMPOSE ps

echo "👉 Kibana: http://127.0.0.1:5601"
echo "🎉 安裝完成！"
