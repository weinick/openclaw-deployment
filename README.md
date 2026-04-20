# OpenClaw AWS Deployment

CloudFormation部署OpenClaw到AWS，包含ALB、HTTPS和分层认证。

## 安全架构

### 认证分层设计

| 访问路径 | 认证方式 | 适用场景 |
|---------|---------|--------|
| `/` (Control UI) | **Cognito认证** | 管理员通过浏览器访问 |
| `/hooks/*` | **Bearer Token** | Channel webhook接入 |
| `/api/*` | **Bearer Token** | Gateway API调用 |
| `/v1/*` | **Bearer Token** | OpenAI兼容API |
| `/health` | 无认证 | ALB健康检查 |

### 安全特性

- ✅ **WAF保护**: AWS Managed Rules + Rate Limiting
- ✅ **HTTPS强制**: TLS终止在ALB
- ✅ **双重认证**: Web UI使用Cognito，API使用Bearer Token
- ✅ **网络隔离**: EC2无公网IP，仅通过ALB访问
- ✅ **Token管理**: 自动生成并存储在SSM Parameter Store

## 文件说明

- `openclaw-deployment.yaml` - CloudFormation模板（Linux ARM64）
- `openclaw-mac-deployment.yaml` - macOS EC2 CloudFormation模板
- `deploy-openclaw.sh` - 通用部署脚本（支持任意region）
- `delete-openclaw.sh` - 删除堆栈脚本
- `docs/openclaw-architecture.drawio` - 架构图（draw.io格式）

## 快速部署

### 1. 准备证书
在ACM中创建或导入域名证书，记录ARN。

### 2. 部署堆栈
```bash
./deploy-openclaw.sh \
  --region ap-southeast-1 \
  --stack-name openclaw-sgp \
  --domain openclaw.example.com \
  --email admin@example.com \
  --password YourPassword123! \
  --cert-arn arn:aws:acm:ap-southeast-1:123456789:certificate/xxx
```

启用CloudFront：
```bash
./deploy-openclaw.sh \
  --region ap-southeast-1 \
  --stack-name openclaw-sgp \
  --domain openclaw.example.com \
  --email admin@example.com \
  --password YourPassword123! \
  --cert-arn arn:aws:acm:ap-southeast-1:123456789:certificate/xxx \
  --enable-cf true \
  --cf-cert-arn arn:aws:acm:us-east-1:123456789:certificate/yyy
```

更多选项：`./deploy-openclaw.sh --help`

### 3. 配置DNS
部署完成后，将域名CNAME指向ALB DNS（从Outputs获取）。
- 如果启用了CloudFront，CNAME指向CloudFront域名（从Outputs的`CloudFrontDomainName`获取）
- 如果未启用CloudFront，CNAME指向ALB DNS（从Outputs的`ALBDNSName`获取）

### 4. 获取Gateway Token

```bash
# 从SSM Parameter Store获取（替换region和stack-name）
aws ssm get-parameter \
  --region <region> \
  --name "/openclaw/<stack-name>/gateway-token" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text
```

### 5. 首次访问 - Device Pairing

首次通过浏览器访问Control UI时，需要完成device pairing：

1. 浏览器访问 `https://your-domain.com`，通过Cognito登录
2. 页面会显示 "pairing required"，这是正常的
3. 通过SSM Session Manager远程批准pairing请求：

```bash
# 查看pending的pairing请求
aws ssm send-command \
  --region <region> \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo -u openclaw openclaw devices list --token $(cat /home/openclaw/.openclaw/openclaw.json | python3 -c \"import sys,json; print(json.load(sys.stdin)[\\\"gateway\\\"][\\\"auth\\\"][\\\"token\\\"])\") 2>&1"]'

# 获取命令结果（替换command-id）
aws ssm get-command-invocation \
  --region <region> \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --query 'StandardOutputContent' \
  --output text
```

4. 从输出中找到pending设备的Request ID，然后批准：

```bash
aws ssm send-command \
  --region <region> \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo -u openclaw openclaw devices approve <request-id> --token $(cat /home/openclaw/.openclaw/openclaw.json | python3 -c \"import sys,json; print(json.load(sys.stdin)[\\\"gateway\\\"][\\\"auth\\\"][\\\"token\\\"])\") 2>&1"]'
```

5. 刷新浏览器页面，Control UI应该可以正常使用了

### 6. 验证服务状态

```bash
# 检查EC2上的服务状态
aws ssm send-command \
  --region <region> \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl is-active openclaw","systemctl is-active openclaw-proxy","curl -s -o /dev/null -w %{http_code} http://127.0.0.1:18790/"]'

# 检查ALB Target Group健康状态
aws elbv2 describe-target-health \
  --region <region> \
  --target-group-arn <target-group-arn> \
  --query 'TargetHealthDescriptions[0].TargetHealth.State'
```

### 7. 访问
访问 `https://your-domain.com`，使用AdminEmail和AdminPassword登录。

## 主要参数

| 参数 | 说明 | 示例 |
|------|------|------|
| DomainName | 域名 | openclaw.example.com |
| AdminEmail | 管理员邮箱（登录用户名） | admin@example.com |
| AdminPassword | 管理员密码 | 至少8位，包含大小写字母和数字 |
| ExistingCertificateArn | ACM证书ARN | arn:aws:acm:region:account:certificate/... |
| BedrockRegion | Bedrock区域（需和模型所在region一致） | us-east-1 |
| BedrockModelId | Bedrock模型 | bedrock/us.anthropic.claude-sonnet-4-6 |
| InstanceType | EC2实例类型 | t4g.xlarge (默认) |
| EnableWAF | 启用WAF | true (默认) |
| EnableCloudFront | 启用CloudFront（限制ALB仅CloudFront可访问） | false (默认) |
| CloudFrontCertificateArn | CloudFront证书ARN（us-east-1，启用CloudFront时必填） | arn:aws:acm:us-east-1:... |

## 架构说明

- **VPC**: 新建VPC，2个公有子网
- **EC2**: 运行OpenClaw服务（Ubuntu 24.04 ARM64, 100GB gp3）
  - OpenClaw Gateway: 监听 `127.0.0.1:18790` (loopback only)
  - Socat端口转发: `0.0.0.0:18789 → 127.0.0.1:18790`
  - 作用: 允许ALB访问loopback绑定的Gateway，同时保持纵深防御
  - Gateway认证: Token模式（`auth.token`）
  - Bedrock认证: IAM Role + `AWS_PROFILE=default`
  - openclaw用户有sudo权限
- **ALB**: HTTPS监听器，集成Cognito认证
  - 默认规则: Cognito认证 → 转发到Gateway
  - `/hooks/*` `/api/*` `/v1/*`: 绕过Cognito，Gateway用Bearer Token认证
  - `/health`: 无认证，ALB健康检查
- **CloudFront** (可选): CDN加速，启用后ALB安全组仅允许CloudFront IP
- **Cognito**: User Pool管理用户认证
- **WAF**: 保护ALB，限制访问频率
- **IAM**: EC2角色访问Bedrock（含AdminAccess）
- **SSM Parameter Store**: 存储Gateway Token
- **AWS Backup**: 每日自动备份EC2，保留7天
- **Elastic IP**: EC2固定公网IP

## 删除堆栈

```bash
./delete-openclaw.sh --region <region> --stack-name <stack-name>
```

## API访问

### 获取Gateway Token

部署完成后，从CloudFormation Outputs获取token命令：

```bash
# 方法1: 从SSM Parameter Store获取
aws ssm get-parameter \
  --region <region> \
  --name /openclaw/<stack-name>/gateway-token \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text

# 方法2: 从CloudFormation Outputs复制命令
aws cloudformation describe-stacks \
  --stack-name <stack-name> \
  --query 'Stacks[0].Outputs[?OutputKey==`GatewayTokenCommand`].OutputValue' \
  --output text
```

### 使用Bearer Token访问API

```bash
# 设置token变量
export GATEWAY_TOKEN=$(aws ssm get-parameter \
  --region <region> \
  --name /openclaw/<stack-name>/gateway-token \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)

# 访问API
curl -H "Authorization: Bearer $GATEWAY_TOKEN" \
  https://your-domain.com/api/sessions

# 访问OpenAI兼容API
curl -H "Authorization: Bearer $GATEWAY_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock/us.anthropic.claude-sonnet-4-6","messages":[{"role":"user","content":"Hello"}]}' \
  https://your-domain.com/v1/chat/completions

# Channel webhook (例如Telegram)
# Telegram会自动发送POST请求到 https://your-domain.com/hooks/telegram
# 需要在Telegram Bot配置中设置webhook URL并包含token
```

### 配置Channel Webhook

如果使用需要webhook的channels (如Telegram、Discord)：

```bash
# Telegram示例
curl -X POST "https://api.telegram.org/bot<BOT_TOKEN>/setWebhook" \
  -H "Content-Type: application/json" \
  -d "{
    \"url\": \"https://your-domain.com/hooks/telegram\",
    \"secret_token\": \"$GATEWAY_TOKEN\"
  }"
```

**注意**: QQ Bot使用WebSocket连接，不需要webhook配置。

## 故障排查

### 无法访问（502 Bad Gateway）
- 检查DNS是否正确指向ALB（或CloudFront）
- 检查ALB安全组是否允许443端口（启用CloudFront时仅允许CloudFront IP）
- 检查Target Group健康状态
- 检查openclaw和openclaw-proxy服务是否运行
- 检查socat proxy是否挂掉（gateway反复重启时socat可能跟着挂）

### 服务反复重启（Config invalid）
- OpenClaw agent可能修改了`openclaw.json`写入不合法的配置
- 通过SSM查看日志：`journalctl -u openclaw --no-pager -n 20`
- 常见原因：`cron.jobs`（旧格式）、不认识的配置key
- 修复：通过SSM运行 `sudo -u openclaw openclaw doctor --fix` 或手动编辑配置文件

### Bedrock调用失败（No API key found）
- 确认systemd服务中有 `Environment=AWS_PROFILE=default`
- 确认EC2 IAM角色有bedrock:InvokeModel权限
- 确认BedrockRegion参数正确
- 确认模型ID正确（如 `bedrock/us.anthropic.claude-sonnet-4-6`）

### Device Pairing Required
- 首次部署后需要通过SSM远程批准pairing（见部署步骤5）
- Gateway重启后已批准的设备不需要重新pairing

### 登录失败
- 确认用户已创建：检查Cognito User Pool
- 确认密码正确
- 检查Cognito Client配置

### Context Window显示异常（58K/32K）
- 新建session即可（`/new`），旧session缓存了错误的context window值
- 确认 `models.bedrockDiscovery.defaultContextWindow` 设置正确
