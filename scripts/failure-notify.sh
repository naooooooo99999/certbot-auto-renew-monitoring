#!/bin/bash

# Let's Encrypt 証明書更新失敗通知スクリプト
# CloudWatch Logs に失敗通知を送信

set -euo pipefail

# 設定値（setup.shで書き換え可能）
LOG_GROUP_NAME="/aws/ec2/certbot-auto-renew-monitoring"
LOG_STREAM_NAME="$(hostname)-$(date '+%Y%m%d')"
LOCAL_LOG_FILE="/var/log/certbot-auto-renew.log"

# ログ出力関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# CloudWatch Logsにメッセージを送信
send_to_cloudwatch() {
    local message="$1"
    local timestamp=$(date +%s%3N)
    
    # ログストリームの存在確認・作成
    if ! aws logs describe-log-streams \
        --log-group-name "$LOG_GROUP_NAME" \
        --log-stream-name-prefix "$LOG_STREAM_NAME" \
        --query "logStreams[?logStreamName=='$LOG_STREAM_NAME']" \
        --output text 2>/dev/null | grep -q "$LOG_STREAM_NAME"; then
        
        log "INFO: ログストリーム $LOG_STREAM_NAME を作成します"
        aws logs create-log-stream \
            --log-group-name "$LOG_GROUP_NAME" \
            --log-stream-name "$LOG_STREAM_NAME"
    fi
    
    # ログイベント送信
    aws logs put-log-events \
        --log-group-name "$LOG_GROUP_NAME" \
        --log-stream-name "$LOG_STREAM_NAME" \
        --log-events timestamp="$timestamp",message="$message"
}

# メイン処理
main() {
    log "INFO: 失敗通知を開始します"
    
    # 失敗メッセージ作成
    local hostname=$(hostname)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S JST')
    local last_log_lines=""
    
    # ローカルログファイルの最後の10行を取得
    if [[ -f "$LOCAL_LOG_FILE" ]]; then
        last_log_lines=$(tail -n 10 "$LOCAL_LOG_FILE" 2>/dev/null || echo "ログファイルの読み取りに失敗")
    else
        last_log_lines="ローカルログファイルが見つかりません: $LOCAL_LOG_FILE"
    fi
    
    # CloudWatch Logsに送信するメッセージ
    local message="[CERTBOT AUTO-RENEW FAILURE]
ホスト: $hostname
時刻: $timestamp
状況: Let's Encrypt証明書の自動更新に失敗しました

最新のログ:
$last_log_lines"
    
    # CloudWatch Logsに送信
    if send_to_cloudwatch "$message"; then
        log "INFO: CloudWatch Logs への通知が成功しました"
    else
        log "ERROR: CloudWatch Logs への通知が失敗しました"
        exit 1
    fi
    
    log "INFO: 失敗通知を完了しました"
}

# スクリプト実行
main "$@"