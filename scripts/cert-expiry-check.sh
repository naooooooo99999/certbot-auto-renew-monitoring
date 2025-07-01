#!/bin/bash

# Let's Encrypt 証明書有効期限チェックスクリプト
# 証明書の有効期限が5日以内になったら CloudWatch Logs に通知

set -euo pipefail

# 設定値（setup.shで書き換え可能）
LOG_GROUP_NAME="/aws/ec2/certbot-auto-renew-monitoring"
LOG_STREAM_NAME="$(hostname)-expiry-check-$(date '+%Y%m%d')"
CERTS_DIR="/etc/letsencrypt/live"
WARNING_DAYS=5
LOCAL_LOG_FILE="/var/log/certbot-expiry-check.log"

# ログ出力関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOCAL_LOG_FILE" >&2
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

# 証明書の有効期限をチェック
check_certificate_expiry() {
    local cert_path="$1"
    local domain="$2"
    
    if [[ ! -f "$cert_path" ]]; then
        log "WARNING: 証明書ファイルが見つかりません: $cert_path"
        return 1
    fi
    
    # 証明書の有効期限を取得
    local expiry_date
    expiry_date=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
    
    # 有効期限をエポック秒に変換
    local expiry_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s)
    
    # 現在時刻をエポック秒に変換
    local current_epoch
    current_epoch=$(date +%s)
    
    # 残り日数を計算
    local remaining_seconds=$((expiry_epoch - current_epoch))
    local remaining_days=$((remaining_seconds / 86400))
    
    log "INFO: ドメイン $domain の有効期限まで残り $remaining_days 日"
    
    # 警告日数以内かチェック
    if [[ $remaining_days -le $WARNING_DAYS ]]; then
        return 0  # 警告が必要
    else
        return 1  # 警告不要
    fi
}

# メイン処理
main() {
    log "INFO: 証明書有効期限チェックを開始します"
    
    # 証明書ディレクトリの存在確認
    if [[ ! -d "$CERTS_DIR" ]]; then
        log "ERROR: 証明書ディレクトリが存在しません: $CERTS_DIR"
        exit 1
    fi
    
    local warning_needed=false
    local warning_domains=()
    local warning_details=""
    
    # 各ドメインの証明書をチェック
    for domain_dir in "$CERTS_DIR"/*; do
        if [[ -d "$domain_dir" ]]; then
            local domain=$(basename "$domain_dir")
            local cert_file="$domain_dir/cert.pem"
            
            log "INFO: ドメイン $domain の証明書をチェックします"
            
            if check_certificate_expiry "$cert_file" "$domain"; then
                warning_needed=true
                warning_domains+=("$domain")
                
                # 有効期限の詳細情報を取得
                local expiry_date
                expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | cut -d= -f2)
                local expiry_epoch
                expiry_epoch=$(date -d "$expiry_date" +%s)
                local current_epoch
                current_epoch=$(date +%s)
                local remaining_days=$(((expiry_epoch - current_epoch) / 86400))
                
                warning_details="${warning_details}ドメイン: $domain\n"
                warning_details="${warning_details}有効期限: $expiry_date\n"
                warning_details="${warning_details}残り日数: $remaining_days 日\n\n"
                
                log "WARNING: ドメイン $domain の証明書が $remaining_days 日後に期限切れになります"
            fi
        fi
    done
    
    # 警告が必要な場合はCloudWatch Logsに送信
    if [[ "$warning_needed" == true ]]; then
        local hostname=$(hostname)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S JST')
        
        local message="[CERTBOT CERTIFICATE EXPIRY WARNING]
ホスト: $hostname
時刻: $timestamp
状況: Let's Encrypt証明書の有効期限が近づいています

警告しきい値: $WARNING_DAYS 日以内
対象ドメイン数: ${#warning_domains[@]}

詳細:
$(echo -e "$warning_details")"
        
        if send_to_cloudwatch "$message"; then
            log "INFO: CloudWatch Logs への有効期限警告通知が成功しました"
        else
            log "ERROR: CloudWatch Logs への有効期限警告通知が失敗しました"
            exit 1
        fi
    else
        log "INFO: 有効期限警告の対象証明書はありませんでした"
    fi
    
    log "INFO: 証明書有効期限チェックを完了しました"
}

# スクリプト実行
main "$@"