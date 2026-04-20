#!/bin/bash
set -e

# Usage: ./deploy-openclaw.sh --region <region> --stack-name <name> --domain <domain> --email <email> --password <password> --cert-arn <arn> [options]
# Example: ./deploy-openclaw.sh --region ap-southeast-1 --stack-name openclaw-sgp --domain openclaw.example.com --email admin@example.com --password MyPass123! --cert-arn arn:aws:acm:...

usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Required:"
  echo "  --region        AWS region (e.g., ap-southeast-1, us-east-1)"
  echo "  --stack-name    CloudFormation stack name"
  echo "  --domain        Domain name for OpenClaw"
  echo "  --email         Admin email (Cognito login)"
  echo "  --password      Admin password (min 8 chars, uppercase+lowercase+number)"
  echo "  --cert-arn      ACM certificate ARN for ALB HTTPS"
  echo ""
  echo "Optional:"
  echo "  --model         Bedrock model ID (default: bedrock/us.anthropic.claude-sonnet-4-6)"
  echo "  --bedrock-region  Bedrock region (default: us-east-1)"
  echo "  --instance-type EC2 instance type (default: t4g.xlarge)"
  echo "  --enable-waf    Enable WAF (default: true)"
  echo "  --enable-cf     Enable CloudFront (default: false)"
  echo "  --cf-cert-arn   CloudFront certificate ARN in us-east-1 (required if --enable-cf)"
  echo "  --help          Show this help"
  exit 1
}

# Defaults
MODEL="bedrock/us.anthropic.claude-sonnet-4-6"
BEDROCK_REGION="us-east-1"
INSTANCE_TYPE="t4g.xlarge"
ENABLE_WAF="true"
ENABLE_CF="false"
CF_CERT_ARN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    --stack-name) STACK_NAME="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --cert-arn) CERT_ARN="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --bedrock-region) BEDROCK_REGION="$2"; shift 2 ;;
    --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
    --enable-waf) ENABLE_WAF="$2"; shift 2 ;;
    --enable-cf) ENABLE_CF="$2"; shift 2 ;;
    --cf-cert-arn) CF_CERT_ARN="$2"; shift 2 ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Validate required params
if [ -z "$REGION" ] || [ -z "$STACK_NAME" ] || [ -z "$DOMAIN" ] || [ -z "$EMAIL" ] || [ -z "$PASSWORD" ] || [ -z "$CERT_ARN" ]; then
  echo "❌ Missing required parameters"
  usage
fi

if [ "$ENABLE_CF" = "true" ] && [ -z "$CF_CERT_ARN" ]; then
  echo "❌ --cf-cert-arn is required when --enable-cf is true"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Deploying OpenClaw to $REGION..."
echo "   Stack: $STACK_NAME"
echo "   Domain: $DOMAIN"
echo "   Model: $MODEL"
echo "   CloudFront: $ENABLE_CF"
echo ""

aws cloudformation create-stack \
  --stack-name "$STACK_NAME" \
  --template-body "file://$SCRIPT_DIR/openclaw-deployment.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=DomainName,ParameterValue="$DOMAIN" \
    ParameterKey=AdminEmail,ParameterValue="$EMAIL" \
    ParameterKey=AdminPassword,ParameterValue="$PASSWORD" \
    ParameterKey=UseRoute53AutoValidation,ParameterValue=false \
    ParameterKey=CreateNewHostedZone,ParameterValue=false \
    ParameterKey=Route53ZoneName,ParameterValue="" \
    ParameterKey=ExistingHostedZoneId,ParameterValue="" \
    ParameterKey=ExistingCertificateArn,ParameterValue="$CERT_ARN" \
    ParameterKey=CreateNewVPC,ParameterValue=true \
    ParameterKey=ExistingVPCId,ParameterValue="" \
    ParameterKey=ExistingSubnet1Id,ParameterValue="" \
    ParameterKey=ExistingSubnet2Id,ParameterValue="" \
    ParameterKey=EnableWAF,ParameterValue="$ENABLE_WAF" \
    ParameterKey=BedrockModelId,ParameterValue="$MODEL" \
    ParameterKey=BedrockRegion,ParameterValue="$BEDROCK_REGION" \
    ParameterKey=InstanceType,ParameterValue="$INSTANCE_TYPE" \
    ParameterKey=EnableCloudFront,ParameterValue="$ENABLE_CF" \
    ParameterKey=CloudFrontCertificateArn,ParameterValue="$CF_CERT_ARN" \
  --region "$REGION"

echo "⏳ Waiting for stack creation..."
aws cloudformation wait stack-create-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo ""
echo "✅ Stack created successfully!"
echo ""
echo "📊 Outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 OpenClaw deployment complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📍 Next steps:"
echo "   1. Configure DNS: CNAME $DOMAIN → (see ALBDNSName or CloudFrontDomainName above)"
echo "   2. Get token: aws ssm get-parameter --region $REGION --name /openclaw/$STACK_NAME/gateway-token --with-decryption --query Parameter.Value --output text"
echo "   3. Open https://$DOMAIN and login with $EMAIL"
echo "   4. Approve device pairing via SSM (see README for details)"
echo ""
