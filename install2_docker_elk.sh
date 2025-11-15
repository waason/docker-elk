#!/usr/bin/env bash
# =========================================================
# 🚀 Ubuntu 24.04 - Docker + docker-elk + Fleet Offline Agent 9.2.0
#     完整安裝腳本 (無最後檢查程序，包含離線 agent 下載)
# =========================================================
set -Eeuo pipefail

LOG_FILE="install_docker_elk_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "=============================================="
echo "🐳 Docker + docker-elk 安裝腳本開始"
echo "📅 $(date)"
echo "📂 Log：$LOG_FILE"
echo "=============================================="

# ----------- 函式 -----------
wait_for_apt_unlock() {
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    echo "⏳ apt 被鎖定，等待中..."
    sleep 5
  done
}

in_group() {
  id -nG "$USER" | tr ' ' '\n' | grep -qx "$1"
}

# ----------- 基本工具 -----------
echo "📦 安裝必要工具 curl / jq..."
wait_for_apt_unlock
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release jq wget

# Elastic Stack 版本固定
ELK_VER="9.2.0"
echo "ℹ️ 使用 Elastic Stack 版本：${ELK_VER}"

# ----------- 密碼輸入 -----------
echo -n "🔐 請輸入 Elasticsearch『elastic』密碼： "
read -rs ELASTIC_PASSWORD; echo
echo -n "🔐 請輸入 Kibana『kibana_system』密碼（可相同）： "
read -rs KIBANA_PASSWORD; echo

# ----------- Docker 安裝 -----------
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 安裝 Docker..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  wait_for_apt_unlock
  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "✅ Docker 已存在，略過安裝"
fi

# docker 群組
if ! in_group docker; then
  echo "👤 將使用者加入 docker 群組（下次登入生效）..."
  sudo groupadd docker 2>/dev/null || true
  sudo usermod -aG docker "$USER" || true
  DOCKER="sudo docker"
else
  DOCKER="docker"
fi
COMPOSE="$DOCKER compose"

# ----------- 建立 FortiGate / Windows Log 資料夾 -----------
echo "📂 建立 FortiGate / Windows EVTX 目錄..."

FGT_DIR="/home/cape/Documents/fortigate_logs"
EVTX_DIR="/home/cape/Documents/win_evtx_log"

sudo install -d -m 2775 -o "$USER" -g docker "$FGT_DIR" "$EVTX_DIR" || true
sudo chmod 2775 "$FGT_DIR" "$EVTX_DIR"

echo "✅ 已建立："
ls -ld "$FGT_DIR" "$EVTX_DIR" || true

# ----------- 進入 docker-elk 專案 -----------
cd "$HOME/docker-elk" || { echo "❌ 找不到 ~/docker-elk"; exit 1; }

# ----------- 離線 Agent 目錄 + 自動下載 -----------
echo "📂 建立 fleet-static-agent-offline 目錄..."

OFFLINE_AGENT_DIR="$(pwd)/fleet-static-agent-offline"
OFFLINE_AGENT_TAR="${OFFLINE_AGENT_DIR}/elastic-agent-${ELK_VER}-linux-x86_64.tar.gz"
OFFLINE_AGENT_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELK_VER}-linux-x86_64.tar.gz"

sudo install -d -m 775 -o "$USER" -g "$USER" "$OFFLINE_AGENT_DIR"

echo "📌 離線 Agent 目錄：$OFFLINE_AGENT_DIR"
echo "📌 預期離線檔案：$OFFLINE_AGENT_TAR"

if [ -f "$OFFLINE_AGENT_TAR" ]; then
  echo "✅ 已存在離線 Agent 檔案，略過下載"
else
  echo "📥 下載 Elastic Agent ${ELK_VER} 離線檔案..."
  echo "    來源：$OFFLINE_AGENT_URL"
  echo "    目標：$OFFLINE_AGENT_TAR"
  wget -O "$OFFLINE_AGENT_TAR" "$OFFLINE_AGENT_URL"
  echo "✅ 下載完成"
fi

# ----------- 寫入 .env -----------
echo "🧾 更新 .env..."

touch .env

sed -i '/^ELK_VERSION=/d' .env || true
sed -i '/^ELASTIC_VERSION=/d' .env || true
sed -i '/^ELASTIC_PASSWORD=/d' .env || true
sed -i '/^KIBANA_PASSWORD=/d' .env || true
sed -i '/^FLEET_URL=/d' .env || true
sed -i '/^FLEET_STATIC_AGENT_URL=/d' .env || true

{
  echo "ELK_VERSION=${ELK_VER}"
  echo "ELASTIC_VERSION=${ELK_VER}"
  echo "ELASTIC_PASSWORD=${ELASTIC_PASSWORD}"
  echo "KIBANA_PASSWORD=${KIBANA_PASSWORD}"
  echo "FLEET_URL=http://kibana:5601"
  echo "FLEET_STATIC_AGENT_URL=https://fleet-server:8220/static/agent/"
} >> .env

echo "✅ .env 已寫入：ELK_VERSION / ELASTIC_VERSION / FLEET_URL / FLEET_STATIC_AGENT_URL"

# ----------- 修正 elastic-agent 映像 -----------
if grep -q 'docker.elastic.co/beats/elastic-agent' docker-compose*.yml 2>/dev/null; then
  echo "🛠️ 修正 elastic-agent 映像路徑為 9.x 用法..."
  sed -i 's#docker.elastic.co/beats/elastic-agent#docker.elastic.co/elastic-agent/elastic-agent#g' docker-compose*.yml
fi

# ----------- 啟動 docker-elk -----------
echo "🐳 啟動 docker-elk..."
$COMPOSE pull
$COMPOSE up setup
$COMPOSE build
$COMPOSE up -d

echo "=============================================="
echo "🎉 docker-elk + Fleet Static Offline Agent 安裝完成！"
echo "📁 離線 Agent：${OFFLINE_AGENT_TAR}"
echo "👉 Kibana: http://127.0.0.1:5601"
echo "📌 Fleet Agent Binary URL (在 .env)：https://fleet-server:8220/static/agent/"
echo "📜 安裝 log：$LOG_FILE"
echo "=============================================="
