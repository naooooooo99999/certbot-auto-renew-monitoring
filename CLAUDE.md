# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## システム概要

Let's Encrypt証明書の自動更新監視システム。EC2 (Amazon Linux 2023) 環境で動作し、systemdタイマーによる自動実行とAWSサービス連携を提供する。

## アーキテクチャ

### コア実行フロー
1. **certbot-renew.sh** → certbot更新実行 → 成功時: Apache restart + backup-certs.sh / 失敗時: failure-notify.sh
2. **cert-expiry-check.sh** → 証明書期限監視（5日以内で警告）
3. **failure-notify.sh** → CloudWatch Logs通知
4. **backup-certs.sh** → S3バックアップ（3世代管理）

### systemdタイマー連携
- **certbot-auto-renew.timer**: 火曜・金曜 01:00に更新実行
- **certbot-expiry-check.timer**: 毎日 02:00に期限チェック
- すべてのサービスファイルで `__INSTALL_DIR__` プレースホルダーを使用

### AWS統合
- **CloudWatch Logs**: 失敗・警告通知の送信先
- **S3**: 証明書バックアップ保存
- **SNS**: CloudWatch Logs経由でのメール通知

## 開発時の重要コマンド

### セットアップとテスト
```bash
# システム全体のセットアップ（対話式）
sudo ./setup.sh

# 個別スクリプトのテスト実行
sudo ./scripts/certbot-renew.sh
sudo ./scripts/cert-expiry-check.sh
sudo ./scripts/backup-certs.sh
sudo ./scripts/failure-notify.sh

# systemdサービスの手動実行
sudo systemctl start certbot-auto-renew.service
sudo systemctl start certbot-expiry-check.service
```

### 運用確認
```bash
# タイマー状態確認
sudo systemctl status certbot-auto-renew.timer
sudo systemctl list-timers | grep certbot

# ログ確認
sudo tail -f /var/log/certbot-auto-renew.log
sudo journalctl -u certbot-auto-renew.service -f
```

## 設定の動的置換システム

**setup.sh**は以下の設定値を対話的に取得し、スクリプトとsystemdファイルに動的に適用:
- `LOG_GROUP_NAME`: CloudWatch Logsログループ
- `S3_BUCKET`: バックアップ先S3バケット  
- `SNS_TOPIC`: 通知先SNSトピック
- `INSTALL_DIR`: インストールディレクトリ（systemdの`__INSTALL_DIR__`を置換）

**重要**: systemdサービスファイル内の`__INSTALL_DIR__`プレースホルダーは、setup.sh実行時に実際のパスに置換される。直接編集時は注意が必要。

## ログ出力アーキテクチャ

全スクリプトで統一されたログ出力方式を採用:
- **標準エラー出力**: リアルタイム表示用（`>&2`）
- **ローカルログファイル**: 永続化用（`tee -a "$LOCAL_LOG_FILE"`）
- **変数命名**: `LOCAL_LOG_FILE`（CloudWatch Logs変数と区別）

```bash
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOCAL_LOG_FILE" >&2
}
```

これにより関数の戻り値にログが混入せず、データとログが適切に分離される。

## 認証方式の対応

- **Apache認証**: HTTP-01チャレンジ（ポート80必須）
- **Route53 DNS認証**: DNS-01チャレンジ（追加IAM権限とpython3-certbot-dns-route53が必要）

Route53使用時は追加のIAM権限（route53:ListHostedZones, route53:GetChange, route53:ChangeResourceRecordSets）が必要。

## デバッグとトラブルシューティング

### ログファイルの場所
- `/var/log/certbot-auto-renew.log`: 自動更新ログ
- `/var/log/certbot-expiry-check.log`: 有効期限チェックログ
- `journalctl -u [service-name]`: systemdログ

### AWS権限エラーの確認
```bash
# AWS認証状態確認
aws sts get-caller-identity

# CloudWatch Logs書き込みテスト
aws logs describe-log-groups --log-group-name-prefix /aws/ec2/certbot

# S3アクセステスト  
aws s3 ls s3://[bucket-name]/
```

### 設定値の検証
スクリプト内のデフォルト値は変数として定義されており、setup.shで書き換えられる。手動編集時は各スクリプトの設定値セクションを確認すること。

### 重要な実装詳細

**関数の戻り値**: `create_backup()` などの関数は `echo` で戻り値を返すため、ログ出力は必ず標準エラー出力（`>&2`）に送ること。

**systemdタイマー**: ローカルタイムゾーンで動作するため、UTC変換は不要。EC2のタイムゾーン設定に従って実行される。

**AWS認証**: IAMロールによる認証を前提。Route53 DNS認証使用時は追加のRoute53権限が必要。