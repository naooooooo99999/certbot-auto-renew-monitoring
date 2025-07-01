#!/bin/bash

# Let's Encrypt 証明書バックアップスクリプト
# /etc/letsencrypt/ を tar.gz で固めて S3 にアップロード
# 最新三世代分だけ残し、それ以前は削除

set -euo pipefail

# 設定値（setup.shで書き換え可能）
S3_BUCKET="certbot-auto-renew-backup"
BACKUP_SOURCE="/etc/letsencrypt"
BACKUP_GENERATIONS=3
LOCAL_LOG_FILE="/var/log/certbot-auto-renew.log"

# ログ出力関数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOCAL_LOG_FILE" >&2
}

# バックアップファイル作成
create_backup() {
    local backup_filename="letsencrypt-$(hostname)-$(date '+%Y%m%d-%H%M%S').tar.gz"
    local temp_backup_path="/tmp/$backup_filename"
    
    log "INFO: バックアップファイルを作成します: $backup_filename"
    
    # tar.gz作成
    if tar -czf "$temp_backup_path" -C "$(dirname "$BACKUP_SOURCE")" "$(basename "$BACKUP_SOURCE")"; then
        log "INFO: バックアップファイル作成が成功しました"
        echo "$temp_backup_path"
    else
        log "ERROR: バックアップファイル作成が失敗しました"
        return 1
    fi
}

# S3にアップロード
upload_to_s3() {
    local backup_file="$1"
    local filename=$(basename "$backup_file")
    
    log "INFO: S3にアップロードします: s3://$S3_BUCKET/$filename"
    
    if aws s3 cp "$backup_file" "s3://$S3_BUCKET/$filename"; then
        log "INFO: S3アップロードが成功しました"
        rm -f "$backup_file"
        return 0
    else
        log "ERROR: S3アップロードが失敗しました"
        rm -f "$backup_file"
        return 1
    fi
}

# 古いバックアップを削除
cleanup_old_backups() {
    local hostname=$(hostname)
    local prefix="letsencrypt-$hostname-"
    
    log "INFO: 古いバックアップの削除処理を開始します"
    
    # S3から対象ホストのバックアップファイル一覧を取得（作成日時順）
    local backup_list
    backup_list=$(aws s3 ls "s3://$S3_BUCKET/" | grep "$prefix" | sort -k1,2 -r) || {
        log "WARNING: バックアップファイル一覧の取得に失敗しました"
        return 0
    }
    
    local count=0
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            count=$((count + 1))
            if [[ $count -gt $BACKUP_GENERATIONS ]]; then
                local filename=$(echo "$line" | awk '{print $4}')
                log "INFO: 古いバックアップを削除します: $filename"
                if aws s3 rm "s3://$S3_BUCKET/$filename"; then
                    log "INFO: バックアップ削除が成功しました: $filename"
                else
                    log "WARNING: バックアップ削除が失敗しました: $filename"
                fi
            fi
        fi
    done <<< "$backup_list"
    
    log "INFO: 古いバックアップの削除処理を完了しました"
}

# メイン処理
main() {
    log "INFO: 証明書バックアップ処理を開始します"
    
    # バックアップソースの存在確認
    if [[ ! -d "$BACKUP_SOURCE" ]]; then
        log "ERROR: バックアップ対象ディレクトリが存在しません: $BACKUP_SOURCE"
        exit 1
    fi
    
    # バックアップファイル作成
    local backup_file
    if backup_file=$(create_backup); then
        # S3にアップロード
        if upload_to_s3 "$backup_file"; then
            # 古いバックアップの削除
            cleanup_old_backups
            log "INFO: 証明書バックアップ処理が完了しました"
        else
            log "ERROR: S3アップロードに失敗しました"
            exit 1
        fi
    else
        log "ERROR: バックアップファイル作成に失敗しました"
        exit 1
    fi
}

# スクリプト実行
main "$@"