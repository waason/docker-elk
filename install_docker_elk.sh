#!/usr/bin/env bash
# =========================================================
# 🚀 Ubuntu 24.04 - Docker + docker-elk 一鍵安裝/啟動腳本（含日誌資料夾建立）
# Author: waason (revised + folders)
# =========================================================
set -Eeuo pipefail

LOG_FILE="install_docker_elk_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "🐳 Docker + docker-elk 安裝啟動腳本開始"
echo "📅 $(date)"
echo "📂 Log 檔案：$LOG_FILE"
echo "=============================================="

# ----------- 工具函式 -----------
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

# ----------- 互動輸入 -----------
read -rp "🔢 請輸入要安裝的 Elastic Stack 版本 (預設 9.0.3)： " ELK_VER_IN
ELK_VER="${ELK_VER_IN:-9.0.3}"

echo -n "🔐 請輸入 Elasticsearch『elastic』使用者密碼： "
read -rs ELASTIC_PASSWORD; echo
echo -n "🔐 請輸入 Kibana『kibana_system』使用者密碼（可與上面相同）： "
read -rs KIBANA_PASSWORD; echo

# ----------- 系統更新 / 安裝 Docker -----------
wait_for_apt_unlock
echo "📦 更新系統套件..."
sudo apt update -y
sudo apt install -y ca-certificates curl gnupg lsb-release jq

if ! command -v docker >/dev/null 2>&1; then
  echo "🔑 新增 Docker 官方 GPG 金鑰..."
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "🧩 加入 Docker 軟體倉庫..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  wait_for_apt_unlock
  echo "⚙️ 安裝 Docker Engine/CLI/Compose plugin..."
  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "✅ 已安裝 Docker。"
fi

# ----------- docker 權限（不阻塞腳本）-----------
if ! in_group docker; then
  echo "👤 將 $USER 加入 docker 群組（下次登入生效，當前腳本自動改用 sudo docker 執行）..."
  sudo groupadd docker 2>/dev/null || true
  sudo usermod -aG docker "$USER" || true
  DOCKER="sudo docker"
else
  DOCKER="docker"
fi
COMPOSE="$DOCKER compose"

echo "✅ Docker 版本：$($DOCKER --version)"
echo "✅ Compose 版本：$($DOCKER compose version)"

# ----------- 建立 FortiGate / Windows EVTX 日誌資料夾 -----------
echo "🗂️ 建立 FortiGate 與 Windows EVTX 日誌資料夾..."
FGT_DIR="/home/cape/Documents/fortigate_logs"
EVTX_DIR="/home/cape/Documents/win_evtx_log"

sudo install -d -m 2775 -o "$USER" -g docker "$FGT_DIR" "$EVTX_DIR" 2>/dev/null || \
  sudo install -d -m 2775 -o "$USER" "$FGT_DIR" "$EVTX_DIR"

if getent group docker >/dev/null 2>&1; then
  sudo chgrp docker "$FGT_DIR" "$EVTX_DIR" || true
fi
sudo chmod 2775 "$FGT_DIR" "$EVTX_DIR"
echo "✅ 目錄建立完成："
ls -ld "$FGT_DIR" "$EVTX_DIR"

# ----------- 進入專案 -----------
if [ -d "$HOME/docker-elk" ]; then
  cd "$HOME/docker-elk"
  echo "📂 切換目錄到 ~/docker-elk"
else
  echo "⚠️ 找不到 ~/docker-elk，請先執行： git clone https://github.com/deviantony/docker-elk.git ~/docker-elk"
  exit 1
fi

# ----------- 設定 .env 版本與密碼 -----------
echo "🧾 設定 .env 版本與密碼..."
touch .env
sed -i '/^ELK_VERSION=/d' .env || true
sed -i '/^ELASTIC_VERSION=/d' .env || true
sed -i '/^ELASTIC_PASSWORD=/d' .env || true
sed -i '/^KIBANA_PASSWORD=/d' .env || true
{
  echo "ELK_VERSION=${ELK_VER}"
  echo "ELASTIC_VERSION=${ELK_VER}"
  echo "ELASTIC_PASSWORD=${ELASTIC_PASSWORD}"
  echo "KIBANA_PASSWORD=${KIBANA_PASSWORD}"
} >> .env
echo "✅ 已寫入 .env（密碼不顯示在輸出）"

# ----------- 修正 elastic-agent 映像路徑（9.x）-----------
if grep -q 'docker.elastic.co/beats/elastic-agent' docker-compose*.yml 2>/dev/null; then
  echo "🛠️ 將 beats/elastic-agent 改為 elastic-agent/elastic-agent（9.x 正確路徑）..."
  sed -i 's#docker.elastic.co/beats/elastic-agent#docker.elastic.co/elastic-agent/elastic-agent#g' docker-compose*.yml
fi

# ----------- 拉映像 / 初始化 / 啟動 -----------
echo "🧱 建立 docker-elk 初始服務..."
$COMPOSE pull
$COMPOSE up setup

echo "🛠️ 建置（如需要）..."
$COMPOSE build

echo "🚀 以背景模式啟動所有服務..."
$COMPOSE up -d

echo "🔍 檢查容器狀態..."
$COMPOSE ps

# ----------- 健康檢查 -----------
echo "🩺 叢集健康檢查（可能需等待數十秒）..."
set +e
ES_VER=""
for i in {1..30}; do
  ES_VER=$($DOCKER run --rm --network "$(basename "$(pwd)")_elk" curlimages/curl:8.9.1 \
    -s -u "elastic:${ELASTIC_PASSWORD}" http://elasticsearch:9200 | jq -r '.version.number' 2>/dev/null)
  if [[ -n "${ES_VER}" && "${ES_VER}" != "null" ]]; then
    break
  fi
  printf "  ⏳ 等待 Elasticsearch 起來中... (%d/30)" "$i"; pause_dot
  sleep 4
done
set -e

if [[ -z "${ES_VER}" || "${ES_VER}" == "null" ]]; then
  echo "❌ 無法取得 Elasticsearch 版本，請檢查："
  echo "   - elastic 密碼是否正確"
  echo "   - elasticsearch 容器是否啟動成功：$COMPOSE logs elasticsearch"
  exit 2
fi

echo "✅ Elasticsearch 版本：${ES_VER}"
echo "👉 Kibana UI： http://127.0.0.1:5601"
echo "   elastic 密碼已套用（依你剛才輸入）"
echo "📜 你可以隨時檢視日誌：tail -f $LOG_FILE"
echo "=============================================="
echo "🎉 完成！如要在『本次登入』就能免 sudo 使用 docker，請手動執行： newgrp docker"
