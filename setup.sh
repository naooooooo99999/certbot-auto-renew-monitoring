#!/bin/bash

# Let's Encrypt 証明書自動更新監視システム セットアップスクリプト

set -euo pipefail

# 設定値のデフォルト
DEFAULT_LOG_GROUP="/aws/ec2/certbot-auto-renew-monitoring"
DEFAULT_S3_BUCKET="certbot-auto-renew-backup"
DEFAULT_SNS_TOPIC="certbot-auto-renew-alerts"
DEFAULT_INSTALL_DIR="/opt/certbot-auto-renew-monitoring"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 色付きログ出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# 実行環境チェック
check_requirements() {
    log_info "実行環境をチェックしています..."

    # root権限チェック
    if [[ $EUID -ne 0 ]]; then
        log_error "このスクリプトはroot権限で実行してください"
        exit 1
    fi

    # 必要なコマンドの存在確認
    local commands=("certbot" "aws" "systemctl" "openssl" "tar")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "必要なコマンドが見つかりません: $cmd"
            echo "インストール方法はREADME.mdを参照してください"
            exit 1
        fi
    done

    # AWS認証情報の確認
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS認証情報が設定されていません"
        echo "AWS CLIの設定を行うか、EC2にIAMロールを割り当ててください"
        exit 1
    fi

    # certbotの証明書存在確認
    if [[ ! -d "/etc/letsencrypt/live" ]] || [[ -z "$(ls -A /etc/letsencrypt/live 2>/dev/null)" ]]; then
        log_error "Let's Encrypt証明書が見つかりません"
        echo "まずcertbotで証明書を取得してください"
        exit 1
    fi

    log_success "実行環境チェック完了"
}

# 設定値の入力
get_configuration() {
    log_info "設定値を入力してください"

    echo -n "CloudWatch Logsのロググループ名 (デフォルト: $DEFAULT_LOG_GROUP): "
    read -r LOG_GROUP_NAME
    LOG_GROUP_NAME=${LOG_GROUP_NAME:-$DEFAULT_LOG_GROUP}

    echo -n "S3バケット名 (デフォルト: $DEFAULT_S3_BUCKET): "
    read -r S3_BUCKET
    S3_BUCKET=${S3_BUCKET:-$DEFAULT_S3_BUCKET}

    echo -n "SNSトピック名 (デフォルト: $DEFAULT_SNS_TOPIC): "
    read -r SNS_TOPIC
    SNS_TOPIC=${SNS_TOPIC:-$DEFAULT_SNS_TOPIC}

    echo -n "インストールディレクトリ (デフォルト: $DEFAULT_INSTALL_DIR): "
    read -r INSTALL_DIR
    INSTALL_DIR=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}

    log_info "設定値:"
    echo "  CloudWatch Logs: $LOG_GROUP_NAME"
    echo "  S3バケット: $S3_BUCKET"
    echo "  SNSトピック: $SNS_TOPIC"
    echo "  インストールディレクトリ: $INSTALL_DIR"

    echo -n "この設定で続行しますか？ (y/N): "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "セットアップを中止しました"
        exit 0
    fi
}

# AWS権限チェック
check_aws_permissions() {
    log_info "AWS権限をチェックしています..."

    # CloudWatch Logs権限チェック
    if ! aws logs describe-log-groups --max-items 1 &>/dev/null; then
        log_error "CloudWatch Logs の DescribeLogGroups 権限がありません"
        log_error "README.md の IAM権限設定を確認してください"
        exit 1
    fi

    # SNS権限チェック
    if ! aws sns list-topics &>/dev/null; then
        log_error "SNS の ListTopics 権限がありません"
        log_error "README.md の IAM権限設定を確認してください"
        exit 1
    fi

    log_success "AWS権限チェック完了"
}

# AWSリソースの作成
create_aws_resources() {
    log_info "AWSリソースを作成しています..."

    # CloudWatch Logsロググループ作成
    if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" --query "logGroups[?logGroupName=='$LOG_GROUP_NAME']" --output text | grep -q "$LOG_GROUP_NAME"; then
        log_info "CloudWatch Logsロググループは既に存在します: $LOG_GROUP_NAME"
    else
        aws logs create-log-group --log-group-name "$LOG_GROUP_NAME"
        log_success "CloudWatch Logsロググループを作成しました: $LOG_GROUP_NAME"
    fi

    # S3バケット作成
    if aws s3 ls "s3://$S3_BUCKET" &> /dev/null; then
        log_info "S3バケットは既に存在します: $S3_BUCKET"
    else
        aws s3 mb "s3://$S3_BUCKET"
        log_success "S3バケットを作成しました: $S3_BUCKET"
    fi

    # SNSトピック作成
    local sns_arn
    if sns_arn=$(aws sns list-topics --query "Topics[?contains(TopicArn, '$SNS_TOPIC')].TopicArn" --output text 2>/dev/null) && [[ -n "$sns_arn" ]]; then
        log_info "SNSトピックは既に存在します: $SNS_TOPIC"
    else
        sns_arn=$(aws sns create-topic --name "$SNS_TOPIC" --query "TopicArn" --output text)
        log_success "SNSトピックを作成しました: $SNS_TOPIC"
        log_info "SNS ARN: $sns_arn"
        log_warning "SNSトピックにメール通知を設定する場合は、AWSコンソールから購読者を追加してください"
    fi
}

# スクリプトファイルの設定
configure_scripts() {
    log_info "スクリプトファイルを設定しています..."

    # インストールディレクトリ作成
    mkdir -p "$INSTALL_DIR/scripts"

    # スクリプトファイルをコピーして設定値を書き換え
    local scripts=("failure-notify.sh" "cert-expiry-check.sh" "backup-certs.sh")

    for script in "${scripts[@]}"; do
        cp "$SCRIPT_DIR/scripts/$script" "$INSTALL_DIR/scripts/"

        # 設定値の書き換え
        case "$script" in
            "failure-notify.sh"|"cert-expiry-check.sh")
                sed -i "s|LOG_GROUP_NAME=\".*\"|LOG_GROUP_NAME=\"$LOG_GROUP_NAME\"|" "$INSTALL_DIR/scripts/$script"
                ;;
            "backup-certs.sh")
                sed -i "s|S3_BUCKET=\".*\"|S3_BUCKET=\"$S3_BUCKET\"|" "$INSTALL_DIR/scripts/$script"
                ;;
        esac

        chmod +x "$INSTALL_DIR/scripts/$script"
        log_success "スクリプトを設定しました: $script"
    done

    # certbot-renew.shをコピー
    cp "$SCRIPT_DIR/scripts/certbot-renew.sh" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/certbot-renew.sh"
    log_success "スクリプトを設定しました: certbot-renew.sh"
}

# systemdサービスの設定
configure_systemd() {
    log_info "systemdサービスを設定しています..."

    # systemdファイルをコピーして設定値を書き換え
    local systemd_files=("certbot-auto-renew.service" "certbot-auto-renew.timer" "certbot-failure-notify.service" "certbot-expiry-check.service" "certbot-expiry-check.timer")

    for file in "${systemd_files[@]}"; do
        cp "$SCRIPT_DIR/systemd/$file" "/etc/systemd/system/"

        # サービスファイルのExecStartパスを書き換え
        if [[ "$file" == *.service ]]; then
            sed -i "s|__INSTALL_DIR__|$INSTALL_DIR|g" "/etc/systemd/system/$file"
        fi

        log_success "systemdファイルをインストールしました: $file"
    done

    # systemdリロード
    systemctl daemon-reload

    # サービスの有効化
    systemctl enable certbot-auto-renew.timer
    systemctl enable certbot-expiry-check.timer

    # タイマーの開始
    if systemctl is-active --quiet certbot-auto-renew.timer; then
        systemctl restart certbot-auto-renew.timer
    else
        systemctl start certbot-auto-renew.timer
    fi

    if systemctl is-active --quiet certbot-expiry-check.timer; then
        systemctl restart certbot-expiry-check.timer
    else
        systemctl start certbot-expiry-check.timer
    fi

    log_success "systemdサービスを設定しました"
}

# ログファイルの作成
create_log_files() {
    log_info "ログファイルを作成しています..."

    touch /var/log/certbot-auto-renew.log
    touch /var/log/certbot-expiry-check.log
    chmod 644 /var/log/certbot-auto-renew.log
    chmod 644 /var/log/certbot-expiry-check.log

    log_success "ログファイルを作成しました"
}

# 設定テスト
test_configuration() {
    log_info "設定をテストしています..."

    # 有効期限チェックのテスト
    log_info "有効期限チェックをテストします..."
    if "$INSTALL_DIR/scripts/cert-expiry-check.sh"; then
        log_success "有効期限チェックのテストが成功しました"
    else
        log_warning "有効期限チェックのテストが失敗しました"
    fi

    # バックアップのテスト
    log_info "バックアップをテストします..."
    if "$INSTALL_DIR/scripts/backup-certs.sh"; then
        log_success "バックアップのテストが成功しました"
    else
        log_warning "バックアップのテストが失敗しました"
    fi

    # systemdタイマーの状態確認
    log_info "systemdタイマーの状態を確認します..."
    systemctl status certbot-auto-renew.timer --no-pager || true
    systemctl status certbot-expiry-check.timer --no-pager || true
}

# メイン処理
main() {
    echo "=================================="
    echo "Let's Encrypt 証明書自動更新監視システム"
    echo "セットアップスクリプト"
    echo "=================================="
    echo

    check_requirements
    get_configuration
    check_aws_permissions
    create_aws_resources
    configure_scripts
    configure_systemd
    create_log_files
    test_configuration

    echo
    log_success "セットアップが完了しました！"
    echo
    echo "次のコマンドで状態を確認できます:"
    echo "  systemctl status certbot-auto-renew.timer"
    echo "  systemctl status certbot-expiry-check.timer"
    echo "  systemctl list-timers | grep certbot"
    echo
    echo "ログファイル:"
    echo "  /var/log/certbot-auto-renew.log"
    echo "  /var/log/certbot-expiry-check.log"
    echo
    echo "手動実行:"
    echo "  systemctl start certbot-auto-renew.service"
    echo "  systemctl start certbot-expiry-check.service"
    echo
}

main "$@"