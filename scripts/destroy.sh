#!/usr/bin/env bash
# ============================================================
# destroy.sh — Tear down the multi-agent lab completely
#
# Auth (pick one):
#   --profile <aws-profile>                     (SSO / named profile)
#   --access-key <key> --secret-key <secret>    (IAM access keys)
#
# Required:
#   --stack  <stack-name>   e.g. multi-agent-lab-abc123
#   --suffix <suffix>       e.g. abc123
#
# Other options:
#   --region <region>       default: eu-west-1
#
# Usage:
#   bash scripts/destroy.sh --stack multi-agent-lab-abc123 --suffix abc123 --profile my-profile
# ============================================================
set -euo pipefail

PROFILE=""
REGION="eu-west-1"
STACK_NAME=""
SUFFIX=""
ACCESS_KEY=""
SECRET_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)     PROFILE="$2";     shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --stack)       STACK_NAME="$2";  shift 2 ;;
    --suffix)      SUFFIX="$2";      shift 2 ;;
    --access-key)  ACCESS_KEY="$2";  shift 2 ;;
    --secret-key)  SECRET_KEY="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$STACK_NAME" ]]; then
  echo "ERROR: --stack <stack-name> is required."
  echo "Usage: ./destroy.sh --stack multi-agent-lab-<suffix> --suffix <suffix> [--profile ...] [--region ...]"
  exit 1
fi

if [[ -z "$SUFFIX" ]]; then
  echo "ERROR: --suffix <suffix> is required."
  exit 1
fi

# ── Auth setup ────────────────────────────────────────────────────────────────
if [[ -n "$ACCESS_KEY" && -n "$SECRET_KEY" ]]; then
  export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  unset AWS_PROFILE 2>/dev/null || true
  PROFILE_ARG=()
  export BOTO3_PROFILE=""
  AUTH_DISPLAY="access key ${ACCESS_KEY:0:8}..."
elif [[ -n "$PROFILE" ]]; then
  PROFILE_ARG=(--profile "$PROFILE")
  export BOTO3_PROFILE="$PROFILE"
  AUTH_DISPLAY="profile=$PROFILE"
else
  echo "ERROR: Provide either --profile <name> or --access-key + --secret-key"
  exit 1
fi

echo "==================================================="
echo " DESTROY: auth=$AUTH_DISPLAY  region=$REGION"
echo "          stack=$STACK_NAME  suffix=$SUFFIX"
echo "==================================================="
read -rp "Are you sure you want to delete all resources? (yes/no): " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ── Resolve bucket names from CFN outputs ────────────────────────────────────
get_output() {
  aws "${PROFILE_ARG[@]}" cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

DATA_BUCKET=$(get_output DataBucketName)
FEEDBACK_BUCKET=$(get_output FeedbackBucketName)
ECR_URI=$(get_output ECRRepositoryUri)

# Fallback to convention-based names if stack outputs are missing
[[ -z "$DATA_BUCKET" || "$DATA_BUCKET" == "None" ]] && DATA_BUCKET="data-bucket-${SUFFIX}"
[[ -z "$FEEDBACK_BUCKET" || "$FEEDBACK_BUCKET" == "None" ]] && FEEDBACK_BUCKET="feedback-bucket-${SUFFIX}"

# ── [1/8] Delete App Runner service ──────────────────────────────────────────
echo ""
echo "=== [1/8] Deleting App Runner service ==="
SERVICE_NAME="multi-agent-app-${SUFFIX}"
SERVICE_ARN=$(aws "${PROFILE_ARG[@]}" apprunner list-services --region "$REGION" \
  --query "ServiceSummaryList[?ServiceName=='$SERVICE_NAME'].ServiceArn" \
  --output text 2>/dev/null || true)

if [[ -n "$SERVICE_ARN" && "$SERVICE_ARN" != "None" ]]; then
  aws "${PROFILE_ARG[@]}" apprunner delete-service \
    --service-arn "$SERVICE_ARN" --region "$REGION" > /dev/null
  echo "  Deleting App Runner service $SERVICE_NAME (async)..."
else
  echo "  App Runner service not found (already deleted)."
fi

# ── [2/8] Empty S3 buckets ───────────────────────────────────────────────────
echo ""
echo "=== [2/8] Emptying S3 buckets ==="
for BUCKET in "$DATA_BUCKET" "$FEEDBACK_BUCKET"; do
  if [[ -n "$BUCKET" ]]; then
    echo "  Emptying $BUCKET ..."
    aws "${PROFILE_ARG[@]}" s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null || true
    python3 - << INNER
import boto3, os
profile = os.environ.get('BOTO3_PROFILE', '')
session = boto3.Session(profile_name=profile or None, region_name='$REGION')
s3 = session.client('s3')
try:
    paginator = s3.get_paginator('list_object_versions')
    count = 0
    for page in paginator.paginate(Bucket='$BUCKET'):
        for obj in page.get('Versions', []) + page.get('DeleteMarkers', []):
            s3.delete_object(Bucket='$BUCKET', Key=obj['Key'], VersionId=obj['VersionId'])
            count += 1
    print(f'    Deleted {count} versions') if count else print('    (nothing to version-delete)')
except Exception as e:
    print(f'    {e}')
INNER
    echo "  $BUCKET emptied."
  fi
done

# ── [3/8] Delete Bedrock Knowledge Base ──────────────────────────────────────
# NOTE: KB must be deleted BEFORE the S3 Vector store, otherwise KB deletion fails
echo ""
echo "=== [3/8] Deleting Bedrock Knowledge Base ==="
python3 - << PYEOF
import boto3, os, time

profile = os.environ.get('BOTO3_PROFILE', '')
session = boto3.Session(profile_name=profile or None, region_name='$REGION')
bedrock = session.client('bedrock-agent')

kbs = bedrock.list_knowledge_bases().get('knowledgeBaseSummaries', [])
for kb in kbs:
    if kb['name'] == 'faqs-kb-$SUFFIX':
        kb_id = kb['knowledgeBaseId']
        print(f"  Found KB: {kb_id}")
        try:
            dss = bedrock.list_data_sources(knowledgeBaseId=kb_id).get('dataSourceSummaries', [])
            for ds in dss:
                bedrock.delete_data_source(knowledgeBaseId=kb_id, dataSourceId=ds['dataSourceId'])
                print(f"  Deleted data source {ds['dataSourceId']}")
            time.sleep(3)
        except Exception as e:
            print(f"  DS delete warning: {e}")
        try:
            bedrock.delete_knowledge_base(knowledgeBaseId=kb_id)
            print(f"  Deleted KB {kb_id}")
        except Exception as e:
            print(f"  KB delete warning: {e}")
        # Wait for KB to fully delete before proceeding to vector store
        for _ in range(12):
            remaining = [k for k in bedrock.list_knowledge_bases().get('knowledgeBaseSummaries', [])
                         if k['knowledgeBaseId'] == kb_id and k['status'] == 'DELETING']
            if not remaining:
                break
            time.sleep(5)
        break
else:
    print("  No KB named 'faqs-kb-$SUFFIX' found (already deleted).")
PYEOF

# ── [4/8] Delete Bedrock Guardrail ───────────────────────────────────────────
echo ""
echo "=== [4/8] Deleting Bedrock Guardrail ==="
python3 - << PYEOF
import boto3, os

profile = os.environ.get('BOTO3_PROFILE', '')
session = boto3.Session(profile_name=profile or None, region_name='$REGION')
bedrock = session.client('bedrock')

gs = bedrock.list_guardrails().get('guardrails', [])
for g in gs:
    if g['name'] == 'multi-agent-guardrail-$SUFFIX':
        try:
            bedrock.delete_guardrail(guardrailIdentifier=g['id'])
            print(f"  Deleted guardrail: {g['id']}")
        except Exception as e:
            print(f"  Guardrail delete warning: {e}")
        break
else:
    print("  No guardrail named 'multi-agent-guardrail-$SUFFIX' found (already deleted).")
PYEOF

# ── [5/8] Delete S3 Vector Bucket & Index ────────────────────────────────────
echo ""
echo "=== [5/8] Deleting S3 Vector Bucket & Index ==="
python3 - << PYEOF
import boto3, os, time

profile = os.environ.get('BOTO3_PROFILE', '')
session = boto3.Session(profile_name=profile or None, region_name='$REGION')
s3v = session.client('s3vectors')

try:
    s3v.delete_index(vectorBucketName='edu-s3-vector', indexName='edu-s3-vector-index')
    print("  Deleted vector index edu-s3-vector-index")
    time.sleep(5)
except Exception as e:
    print(f"  Index delete: {e}")

try:
    s3v.delete_vector_bucket(vectorBucketName='edu-s3-vector')
    print("  Deleted vector bucket edu-s3-vector")
except Exception as e:
    print(f"  Bucket delete: {e}")
PYEOF

# ── [6/8] Delete SageMaker resources ─────────────────────────────────────────
echo ""
echo "=== [6/8] Deleting SageMaker resources ==="
python3 - << PYEOF
import boto3, os

profile = os.environ.get('BOTO3_PROFILE', '')
session = boto3.Session(profile_name=profile or None, region_name='$REGION')
sm = session.client('sagemaker')

for name in ['faq-review-ui-$SUFFIX']:
    try:
        sm.delete_human_task_ui(HumanTaskUiName=name)
        print(f"  Deleted worker task UI: {name}")
    except sm.exceptions.ResourceNotFound:
        print(f"  {name}: not found (already deleted)")
    except Exception as e:
        print(f"  {name}: {e}")

for name in ['escalation-review-workflow-$SUFFIX']:
    try:
        sm.delete_flow_definition(FlowDefinitionName=name)
        print(f"  Deleted flow definition: {name}")
    except sm.exceptions.ResourceNotFound:
        print(f"  {name}: not found (already deleted)")
    except Exception as e:
        print(f"  {name}: {e}")
PYEOF

# ── [7/8] Clean ECR repository ────────────────────────────────────────────────
echo ""
echo "=== [7/8] Cleaning ECR repository ==="
ECR_REPO_NAME="multi-agent-app-${SUFFIX}"
if aws "${PROFILE_ARG[@]}" ecr describe-repositories \
    --repository-names "$ECR_REPO_NAME" --region "$REGION" > /dev/null 2>&1; then
  aws "${PROFILE_ARG[@]}" ecr delete-repository \
    --repository-name "$ECR_REPO_NAME" \
    --force --region "$REGION" > /dev/null
  echo "  ECR repository $ECR_REPO_NAME force-deleted (including all images)."
else
  echo "  ECR repository not found (already deleted)."
fi

# ── [8/8] Delete CloudFormation stack ────────────────────────────────────────
echo ""
echo "=== [8/8] Deleting CloudFormation stack ($STACK_NAME) ==="
if aws "${PROFILE_ARG[@]}" cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" > /dev/null 2>&1; then
  aws "${PROFILE_ARG[@]}" cloudformation delete-stack \
    --stack-name "$STACK_NAME" --region "$REGION"
  echo "  Waiting for stack deletion..."
  aws "${PROFILE_ARG[@]}" cloudformation wait stack-delete-complete \
    --stack-name "$STACK_NAME" --region "$REGION"
  echo "  CloudFormation stack deleted."
else
  echo "  Stack not found (already deleted)."
fi

echo ""
echo "==================================================="
echo " DESTROY COMPLETE — all resources removed from $REGION"
echo "==================================================="
