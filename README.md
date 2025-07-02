# Let's Encrypt 証明書自動更新監視システム

EC2 (Amazon Linux 2023) で Let's Encrypt 証明書の自動更新を行い、CloudWatch Logs と SNS を使った監視・通知システムです。

## 機能

- **自動更新**: 毎週火曜日と金曜日のAM01:00に証明書を自動更新
- **失敗通知**: 更新失敗時にCloudWatch Logsに通知を送信
- **有効期限監視**: 毎日AM02:00に証明書の有効期限をチェック（5日以内で警告）
- **自動バックアップ**: 更新成功時に証明書をS3にバックアップ（最新3世代保持）
- **Apache連携**: 更新成功時にApache graceful restart を実行

## 前提条件

### 必要なパッケージ

```bash
# Amazon Linux 2023での例
sudo dnf update -y
sudo dnf install -y certbot python3-certbot-apache httpd aws-cli openssl tar jq

# Route53 DNS認証を使用する場合は追加で必要
sudo dnf install -y python3-certbot-dns-route53
```

### 事前準備

1. **Let's Encrypt証明書の取得**
   ```bash
   # Apache認証の場合
   sudo certbot certonly --apache -d example.com

   # Route53 DNS認証の場合
   sudo certbot certonly --dns-route53 -d example.com
   ```

2. **AWS認証情報の設定**
   - EC2にIAMロールを割り当てる（推奨）
   - または `aws configure` でアクセスキーを設定

3. **必要なIAM権限**

   **基本権限（全ての認証方式で必要）:**
   ```json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Action": [
                   "logs:CreateLogGroup",
                   "logs:CreateLogStream",
                   "logs:PutLogEvents",
                   "logs:DescribeLogStreams",
                   "logs:DescribeLogGroups"
               ],
               "Resource": "arn:aws:logs:*:*:*"
           },
           {
               "Effect": "Allow",
               "Action": [
                   "s3:CreateBucket",
                   "s3:ListBucket",
                   "s3:GetObject",
                   "s3:PutObject",
                   "s3:DeleteObject"
               ],
               "Resource": [
                   "arn:aws:s3:::certbot-auto-renew-backup",
                   "arn:aws:s3:::certbot-auto-renew-backup/*"
               ]
           },
           {
               "Effect": "Allow",
               "Action": [
                   "sns:CreateTopic",
                   "sns:ListTopics",
                   "sns:Subscribe",
                   "sns:Publish"
               ],
               "Resource": "*"
           }
       ]
   }
   ```

   **Route53 DNS認証を使用する場合の追加権限:**
   ```json
   {
       "Version": "2012-10-17",
       "Statement": [
           {
               "Effect": "Allow",
               "Action": [
                   "route53:ListHostedZones"
               ],
               "Resource": "*"
           },
           {
               "Effect": "Allow",
               "Action": [
                   "route53:GetChange"
               ],
               "Resource": "arn:aws:route53:::change/*"
           },
           {
               "Effect": "Allow",
               "Action": [
                   "route53:ChangeResourceRecordSets"
               ],
               "Resource": [
                   "arn:aws:route53:::hostedzone/YOUR_HOSTED_ZONE_ID"
               ]
           }
       ]
   }
   ```

   **注意**: `YOUR_HOSTED_ZONE_ID` は実際のホストゾーンIDに置き換えてください。

## インストール

1. **リポジトリのクローン**
   ```bash
   git clone git@github.com:naooooooo99999/certbot-auto-renew-monitoring.git
   cd certbot-auto-renew-monitoring
   ```

2. **セットアップ実行**
   ```bash
   sudo ./setup.sh
   ```

3. **設定の確認**
   ```bash
   # タイマーの状態確認
   sudo systemctl status certbot-auto-renew.timer
   sudo systemctl status certbot-expiry-check.timer

   # 次回実行時刻の確認
   sudo systemctl list-timers | grep certbot
   ```

## 設定項目

セットアップ時に以下の設定を行います：

- **CloudWatch Logs**: ログの出力先（デフォルト: `/aws/ec2/certbot-auto-renew-monitoring`）
- **S3バケット**: バックアップの保存先（デフォルト: `certbot-auto-renew-backup`）
  - **注意**: バケット名を変更する場合は、IAM権限の `Resource` で指定しているバケット名も置き換えてください。
- **SNSトピック**: 通知先（デフォルト: `certbot-auto-renew-alerts`）
- **インストールディレクトリ**: スクリプトの配置先（デフォルト: `/opt/certbot-auto-renew-monitoring`）

## ファイル構成

```
[インストールディレクトリ]/
├── scripts/
│   ├── certbot-renew.sh          # 自動更新スクリプト
│   ├── failure-notify.sh         # 失敗通知スクリプト
│   ├── cert-expiry-check.sh      # 有効期限チェックスクリプト
│   └── backup-certs.sh           # バックアップスクリプト
/etc/systemd/system/
├── certbot-auto-renew.service    # 自動更新サービス
├── certbot-auto-renew.timer      # 自動更新タイマー
├── certbot-failure-notify.service # 失敗通知サービス
├── certbot-expiry-check.service  # 有効期限チェックサービス
└── certbot-expiry-check.timer    # 有効期限チェックタイマー
/var/log/
├── certbot-auto-renew.log        # 自動更新ログ
└── certbot-expiry-check.log      # 有効期限チェックログ
```

## 運用

### 手動実行

```bash
# 証明書更新の手動実行
sudo systemctl start certbot-auto-renew.service

# 有効期限チェックの手動実行
sudo systemctl start certbot-expiry-check.service

# 失敗通知の手動実行
sudo systemctl start certbot-failure-notify.service
```

### ログ確認

```bash
# 自動更新ログ
sudo tail -f /var/log/certbot-auto-renew.log

# 有効期限チェックログ
sudo tail -f /var/log/certbot-expiry-check.log

# systemdログ
sudo journalctl -u certbot-auto-renew.service -f
sudo journalctl -u certbot-expiry-check.service -f
```

### タイマー管理

```bash
# タイマー状態確認
sudo systemctl status certbot-auto-renew.timer
sudo systemctl status certbot-expiry-check.timer

# タイマー停止/開始
sudo systemctl stop certbot-auto-renew.timer
sudo systemctl start certbot-auto-renew.timer

# タイマー無効化/有効化
sudo systemctl disable certbot-auto-renew.timer
sudo systemctl enable certbot-auto-renew.timer
```

### CloudWatch Logs設定

AWSコンソールでCloudWatch Logsにメトリクスフィルターを設定し、SNS通知を行います：

1. **CloudWatch Logs** → **ロググループ** → `/aws/ec2/certbot-auto-renew-monitoring`
2. **メトリクスフィルター** を作成:
    1. 失敗通知（入力例）:
        - フィルターパターン: `"[CERTBOT AUTO-RENEW FAILURE]"`
        - フィルター名: `失敗通知`
        - メトリクス名前空間: `CertBot/Monitoring`
        - メトリクス名: `CertbotRenewalFailures`
        - メトリクス値: `1`
        - Unit: カウント
    2. 有効期限警告（入力例）:
        - フィルターパターン: `"[CERTBOT CERTIFICATE EXPIRY WARNING]"`
        - フィルター名: `有効期限警告`
        - メトリクス名前空間: `CertBot/Monitoring`
        - メトリクス名: `CertbotExpiryWarnings`
        - メトリクス値: `1`
        - Unit: カウント
3. **CloudWatch アラーム** を作成:
    1. 失敗通知:
        - 条件: `>= 1`（1回以上の失敗で発火）
        - 通知の送信先: `certbot-auto-renew-alerts`
        - アラーム名: `証明書更新失敗アラーム`
    2. 有効期限警告:
        - 条件: `>= 1`（1回以上の失敗で発火）
        - 通知の送信先: `certbot-auto-renew-alerts`
        - アラーム名: `証明書有効期限警告アラーム`

### SNS設定

1. **SNS** → **トピック** → `certbot-auto-renew-alerts`
2. **サブスクリプション** を作成してメールアドレスを登録

## トラブルシューティング

### 証明書更新が失敗する

```bash
# 手動でcertbot更新を試す
sudo certbot renew --dry-run

# 証明書の状態確認
sudo certbot certificates
```

### CloudWatch Logsに送信されない

```bash
# AWS認証情報の確認
aws sts get-caller-identity

# IAM権限の確認
aws logs describe-log-groups --log-group-name-prefix /aws/ec2/certbot-auto-renew-monitoring
```

### S3バックアップが失敗する

```bash
# S3バケットの確認
aws s3 ls s3://certbot-auto-renew-backup/

# S3権限の確認
aws s3 ls s3://certbot-auto-renew-backup/ --recursive
```

### systemdタイマーが動作しない

```bash
# タイマーの詳細状態確認
sudo systemctl status certbot-auto-renew.timer -l

# タイマーの次回実行時刻確認
sudo systemctl list-timers --all | grep certbot

# systemdログの確認
sudo journalctl -u certbot-auto-renew.timer -f
```

## カスタマイズ

### 実行スケジュールの変更

タイマーファイルを編集して実行スケジュールを変更できます：

```bash
sudo systemctl edit certbot-auto-renew.timer
```

### 警告日数の変更

有効期限チェックスクリプトの `WARNING_DAYS` を変更：

```bash
sudo vi /opt/certbot-auto-renew-monitoring/scripts/cert-expiry-check.sh
```

### バックアップ世代数の変更

バックアップスクリプトの `BACKUP_GENERATIONS` を変更：

```bash
sudo vi /opt/certbot-auto-renew-monitoring/scripts/backup-certs.sh
```

## アンインストール

```bash
# タイマー停止・無効化
sudo systemctl stop certbot-auto-renew.timer certbot-expiry-check.timer
sudo systemctl disable certbot-auto-renew.timer certbot-expiry-check.timer

# systemdファイル削除
sudo rm -f /etc/systemd/system/certbot-*.service /etc/systemd/system/certbot-*.timer
sudo systemctl daemon-reload

# スクリプトファイル削除
sudo rm -rf /opt/certbot-auto-renew-monitoring

# ログファイル削除（オプション）
sudo rm -f /var/log/certbot-auto-renew.log /var/log/certbot-expiry-check.log
```

## ライセンス

MIT License
