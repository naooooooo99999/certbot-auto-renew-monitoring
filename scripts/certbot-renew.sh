#!/bin/bash

# Let's Encrypt 証明書自動更新スクリプト
# 成功時：Apache graceful restart -> バックアップスクリプト実行
# 失敗時：失敗通知サービス実行

set -euo pipefail

# 設定値
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_LOG_FILE="/var/log/certbot-auto-renew.log"
APACHE_SERVICE="httpd"

# ログ出力関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOCAL_LOG_FILE" >&2
}

# メイン処理
main() {
    log "INFO: 証明書更新処理を開始します"
    
    # certbot renew実行
    if certbot renew --quiet --no-self-upgrade; then
        log "INFO: 証明書更新が成功しました"
        
        # Apache graceful restart
        if systemctl reload "$APACHE_SERVICE"; then
            log "INFO: Apache graceful restart が成功しました"
        else
            log "ERROR: Apache graceful restart が失敗しました"
            systemctl start certbot-failure-notify.service
            exit 1
        fi
        
        # バックアップスクリプト実行
        if "$SCRIPT_DIR/backup-certs.sh"; then
            log "INFO: バックアップ作成が成功しました"
        else
            log "WARNING: バックアップ作成が失敗しました"
        fi
        
        log "INFO: 証明書更新処理が完了しました"
    else
        log "ERROR: 証明書更新が失敗しました"
        systemctl start certbot-failure-notify.service
        exit 1
    fi
}

# スクリプト実行
main "$@"