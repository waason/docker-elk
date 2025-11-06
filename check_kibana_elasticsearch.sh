#!/usr/bin/env bash
# =========================================================
# docker-elk 故障排查工具
# 會檢查 Elasticsearch 服務、Kibana 配置以及密碼同步情況
# =========================================================
set -euo pipefail

# 檢查 docker-compose 是否存在
if [[ ! -f docker-compose.yml ]]; then
  echo "❌ 找不到 docker-compose.yml，請在 docker-elk 專案根目錄執行此腳本"
  exit 1
fi

# 檢查 docker 和 curl 是否安裝
if ! command -v docker &>/dev/null; then
  echo "❌ 未安裝 docker"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "❌ 未安裝 curl"
  exit 1
fi

# 讀取 .env 來獲取密碼
ELASTIC_PASSWORD=$(grep ELASTIC_PASSWORD .env | cut -d'=' -f2)
KIBANA_PASSWORD=$(grep KIBANA_SYSTEM_PASSWORD .env | cut -d'=' -f2)

if [[ -z "${ELASTIC_PASSWORD}" || -z "${KIBANA_PASSWORD}" ]]; then
  echo "❌ .env 中找不到 ELASTIC_PASSWORD 或 KIBANA_SYSTEM_PASSWORD，請確認密碼已設置"
  exit 1
fi

echo "=============================================="
echo "🔍 開始診斷："
echo "   - ELASTIC_PASSWORD: ${ELASTIC_PASSWORD}"
echo "   - KIBANA_SYSTEM_PASSWORD: ${KIBANA_PASSWORD}"
echo "=============================================="

# 步驟 1: 檢查 Elasticsearch 服務狀態
echo "⚙️ 檢查 Elasticsearch 健康狀態..."
curl -u elastic:"${ELASTIC_PASSWORD}" http://127.0.0.1:9200/_cluster/health?pretty || { echo "❌ Elasticsearch 連線失敗"; exit 1; }

# 步驟 2: 檢查 kibana_system 密碼是否正確
echo "🔐 檢查 kibana_system 密碼是否有效..."
curl -u kibana_system:"${KIBANA_PASSWORD}" http://127.0.0.1:9200/_security/_authenticate?pretty || { echo "❌ kibana_system 密碼無效"; exit 1; }

# 步驟 3: 檢查 Kibana 日誌
echo "📜 檢查 Kibana 日誌..."
KIBANA_LOGS=$(docker compose logs --tail=30 kibana)
echo "${KIBANA_LOGS}"

# 步驟 4: 如果 Kibana 顯示 "Kibana server is not ready yet."
if [[ "${KIBANA_LOGS}" == *"Kibana server is not ready yet."* ]]; then
  echo "⚠️ Kibana 尚未啟動完成，正在重啟 Kibana 和 Elasticsearch..."

  # 停止並刪除 Kibana 容器
  docker compose stop kibana
  docker compose rm -f kibana

  # 重新啟動所有容器
  docker compose up -d

  echo "✅ 容器重啟完成，請稍等幾分鐘後再次檢查 Kibana"
  exit 0
fi

# 步驟 5: 若 Kibana 還未連線，嘗試重新啟動
echo "🔄 重啟 Kibana 服務..."
docker compose restart kibana

echo "=============================================="
echo "✅ 故障排查完成！"
echo "🔑 如果有需要的話，請再次檢查 Kibana 和 Elasticsearch 是否正常運行。"
echo "=============================================="
