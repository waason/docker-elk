#!/usr/bin/env bash
# =========================================================
# 🔐 docker-elk 密碼重設工具
# Author: waason
# 功能：
#   1. 自動檢查 Elasticsearch 容器
#   2. 自動重設 elastic 與 kibana_system 密碼
#   3. 更新 .env 檔案
# =========================================================
set -e

LOG_FILE="reset_password_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=============================================="
echo "🔐 docker-elk 密碼重設工具開始執行"
echo "📅 $(date)"
echo "📂 Log 檔案：$LOG_FILE"
echo "=============================================="

# 檢查 docker-compose.yml 是否存在
if [ ! -f docker-compose.yml ]; then
  echo "❌ 錯誤：請在 docker-elk 專案根目錄執行此腳本"
  exit 1
fi

# 檢查 Elasticsearch 容器是否運行中
if ! docker compose ps elasticsearch | grep -q "running"; then
  echo "⚙️ Elasticsearch 尚未啟動，嘗試啟動..."
  docker compose up -d elasticsearch
  sleep 15
fi

# 進入容器並重設密碼
echo "🔁 進入 Elasticsearch 容器執行密碼重設..."
CONTAINER_ID=$(docker compose ps -q elasticsearch)

# 重設 elastic 密碼
echo "🧩 重設 superuser: elastic"
ELASTIC_PASS=$(docker exec -i "$CONTAINER_ID" \
  bin/elasticsearch-reset-password --batch --user elastic | grep 'New value' | awk '{print $NF}')

# 重設 kibana_system 密碼
echo "🧩 重設 kibana_system 密碼"
KIBANA_PASS=$(docker exec -i "$CONTAINER_ID" \
  bin/elasticsearch-reset-password --batch --user kibana_system | grep 'New value' | awk '{print $NF}')

echo "✅ Elastic 密碼重設完成"
echo "   elastic = $ELASTIC_PASS"
echo "   kibana_system = $KIBANA_PASS"

# 更新 .env 檔
if [ -f .env ]; then
  echo "📝 更新 .env 中的密碼..."
  sed -i "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=${ELASTIC_PASS}/" .env
  sed -i "s/^KIBANA_SYSTEM_PASSWORD=.*/KIBANA_SYSTEM_PASSWORD=${KIBANA_PASS}/" .env
else
  echo "⚠️ 未找到 .env 檔，建立新檔案"
  echo "ELASTIC_PASSWORD=${ELASTIC_PASS}" > .env
  echo "KIBANA_SYSTEM_PASSWORD=${KIBANA_PASS}" >> .env
fi

# 重啟 Kibana 以套用新密碼
echo "🔄 重啟 Kibana 服務..."
docker compose restart kibana

echo "✅ 密碼重設與同步完成！"
echo "🔑 elastic:        ${ELASTIC_PASS}"
echo "🔑 kibana_system:  ${KIBANA_PASS}"
echo "📘 請用 elastic 帳號登入 Kibana：http://127.0.0.1:5601"
echo "=============================================="
