#!/usr/bin/env bash
set -e

echo "====================================================="
echo " 🚀 Kali Linux: Docker + docker-elk + Fleet + Offline Agent Installer"
echo "====================================================="

PROJECT_DIR="$HOME/docker-elk"
OFFLINE_ROOT="$PROJECT_DIR/fleet-static-agent-offline"
OFFLINE_HTTP_ROOT="$OFFLINE_ROOT/downloads/beats/elastic-agent"
OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"
ENV_FILE="$PROJECT_DIR/.env"

# ------------------------------------------------------------
# 0) 目錄權限防呆修復 FUNCTION
# ------------------------------------------------------------
fix_permissions() {
  echo "🔧 修復目錄權限：$1"
  sudo chown -R $USER:$USER "$1"
  sudo chmod -R 775 "$1"
}

# ------------------------------------------------------------
# 1) Docker 安裝 (Debian bookworm repo)
# ------------------------------------------------------------
echo "🐳 安裝 Docker（Debian bookworm）..."

sudo rm -f /etc/apt/sources.list.d/docker.list || true
sudo rm -f /etc/apt/keyrings/docker.gpg || true

sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release jq

echo "🔐 新增 Docker GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | sudo tee /etc/apt/keyrings/docker.gpg > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "📦 新增 Docker 書源（bookworm）..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian bookworm stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo groupadd docker 2>/dev/null || true
sudo usermod -aG docker "$USER"

echo "🐳 Docker：$(docker --version)"
echo "🐳 Docker Compose：$(docker compose version)"

# ------------------------------------------------------------
# 2) 檢查 docker-elk 專案
# ------------------------------------------------------------
echo "📁 檢查 docker-elk 專案..."

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "❌ 找不到 $PROJECT_DIR"
  echo "請將 docker-elk 專案放到： ~/docker-elk/"
  exit 1
fi

# 目錄權限自動修復
fix_permissions "$PROJECT_DIR"
echo "➡ 使用專案：$PROJECT_DIR"

# ------------------------------------------------------------
# 3) 建立 Fortigate / Windows log 目錄
# ------------------------------------------------------------
echo "📂 建立 log 資料夾..."
mkdir -p "$HOME/Documents/fortigate_logs"
mkdir -p "$HOME/Documents/win_evtx_log"
sudo chmod -R 775 "$HOME/Documents/fortigate_logs" "$HOME/Documents/win_evtx_log"

# ------------------------------------------------------------
# 4) 輸入 Elastic 版本 + 密碼
# ------------------------------------------------------------
read -p "請輸入 Elastic 版本（預設 9.2.0）： " INPUT_VERSION
ELK_VERSION="${INPUT_VERSION:-9.2.0}"

read -s -p "Elastic superuser 密碼：" ELASTIC_PASSWORD
echo ""
read -s -p "Kibana system 密碼：" KIBANA_PASSWORD
echo ""

# ------------------------------------------------------------
# 5) 準備 Offline Elastic Agent
# ------------------------------------------------------------
echo "📦 準備 Offline Elastic Agent..."

fix_permissions "$PROJECT_DIR"

sudo install -d -m 775 -o "$USER" -g "$USER" "$OFFLINE_HTTP_ROOT"

AGENT_TAR="$OFFLINE_HTTP_ROOT/elastic-agent-${ELK_VERSION}-linux-x86_64.tar.gz"
AGENT_URL="https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${ELK_VERSION}-linux-x86_64.tar.gz"

if [[ ! -f "$AGENT_TAR" ]]; then
  echo "🌐 下載 Elastic Agent..."
  if curl -fSL "$AGENT_URL" -o "$AGENT_TAR"; then
    echo "✔ Elastic Agent 下載完成"
  else
    echo "⚠️ 下載失敗，請手動放入：$AGENT_TAR"
  fi
else
  echo "✔ 已存在：$AGENT_TAR"
fi

# ------------------------------------------------------------
# 6) 自動建立 docker-compose.override.yml（含權限防呆）
# ------------------------------------------------------------
fix_permissions "$PROJECT_DIR"

echo "🌐 建立 docker-compose.override.yml..."

cat > "$OVERRIDE_FILE" <<EOF
services:
  agent-artifacts:
    image: nginx:stable
    container_name: agent-artifacts
    volumes:
      - ./fleet-static-agent-offline:/usr/share/nginx/html:ro
    ports:
      - "8080:80"
    networks:
      - elk
EOF

echo "✔ override 建立成功"

# ------------------------------------------------------------
# 7) 寫入 .env（刪除舊設定）
# ------------------------------------------------------------
fix_permissions "$PROJECT_DIR"

echo "🧾 更新 .env..."

sed -i '/ELK_VERSION/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/ELASTIC_VERSION/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/ELASTIC_PASSWORD/d' "$ENV_FILE" 2>/dev/null || true
sed -i '/KIBANA_PASSWORD/d' "$ENV_FILE" 2>/dev/null || true

cat >> "$ENV_FILE" <<EOF
ELK_VERSION=${ELK_VERSION}
ELASTIC_VERSION=${ELK_VERSION}
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_PASSWORD=${KIBANA_PASSWORD}
EOF

echo "✔ .env 寫入完成"

# ------------------------------------------------------------
# 8) 啟動 docker-elk + fleet
# ------------------------------------------------------------
fix_permissions "$PROJECT_DIR"

echo "🚀 啟動 docker-elk + fleet-server..."
cd "$PROJECT_DIR"

docker compose pull
docker compose up setup
docker compose build
docker compose up -d

echo "====================================================="
echo " 🎉 安裝完成！"
echo "====================================================="
echo "Kibana： http://localhost:5601"
echo ""
echo "Fleet → Settings → Agent binary source："
echo "👉 http://agent-artifacts/downloads/"
echo ""
echo "⚠ 建議執行："
echo "sudo usermod -aG docker \$USER"
echo "newgrp docker"
echo "====================================================="
