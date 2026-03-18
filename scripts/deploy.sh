#!/usr/bin/env bash
# ============================================================
# deploy.sh — Automated CloudFormation deployment
#
# Deploys the full multi-agent app stack in 10 steps:
#   1. CloudFormation (S3, IAM, ECR, Lambda, EventBridge)
#   2. Upload FAQ files to S3
#   3. Create S3 Vector bucket + index
#   4. Create Bedrock Knowledge Base
#   5. Create data source + sync FAQs into KB
#   6. Patch Lambda env vars + IAM permissions
#   7. Create SageMaker worker task template
#   8. Create Bedrock Guardrail
#   9. Build Docker image and push to ECR
#  10. Create App Runner service
#
# Auth: pass --profile <name>  OR  --access-key + --secret-key
#
# Usage:
#   bash scripts/deploy.sh --profile my-aws-profile
#   bash scripts/deploy.sh --profile my-profile --region eu-west-1 --suffix abc123
# ============================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROFILE=""
REGION="eu-west-1"
SUFFIX="$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase+string.digits,k=6)))")"
ACCESS_KEY=""
SECRET_KEY=""
STACK_NAME=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)     PROFILE="$2";     shift 2 ;;
    --region)      REGION="$2";      shift 2 ;;
    --suffix)      SUFFIX="$2";      shift 2 ;;
    --access-key)  ACCESS_KEY="$2";  shift 2 ;;
    --secret-key)  SECRET_KEY="$2";  shift 2 ;;
    --stack)       STACK_NAME="$2";  shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

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
  echo "ERROR: provide --profile <name> or --access-key + --secret-key"
  exit 1
fi

[[ -z "$STACK_NAME" ]] && STACK_NAME="multi-agent-lab-${SUFFIX}"
DATA_BUCKET="data-bucket-${SUFFIX}"
FEEDBACK_BUCKET="feedback-bucket-${SUFFIX}"
GUARDRAIL_NAME="multi-agent-guardrail-${SUFFIX}"

echo "==================================================="
echo " DEPLOY multi-agent lab"
echo " Auth    : $AUTH_DISPLAY"
echo " Region  : $REGION"
echo " Suffix  : $SUFFIX"
echo " Stack   : $STACK_NAME"
echo "==================================================="

# ── [0/10] Validate credentials ──────────────────────────────────────────────
echo ""
echo "=== [0/10] Validating AWS credentials ==="
ACCOUNT_ID=$(aws "${PROFILE_ARG[@]}" sts get-caller-identity \
  --query Account --output text --region "$REGION")
echo "  Account: $ACCOUNT_ID  |  Region: $REGION"

# ── [1/10] CloudFormation ────────────────────────────────────────────────────
echo ""
echo "=== [1/10] Deploying CloudFormation stack ==="
aws "${PROFILE_ARG[@]}" cloudformation deploy \
  --template-file "$REPO_DIR/infra/cloudformation.yaml" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides RandomSuffix="$SUFFIX" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"

# Read CF outputs
cf_out() {
  aws "${PROFILE_ARG[@]}" cloudformation describe-stacks \
    --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
BEDROCK_KB_ROLE=$(cf_out BedrockKBRoleArn)
SAGEMAKER_ROLE=$(cf_out SageMakerRoleArn)
LAMBDA_FUNCTION=$(cf_out A2ILambdaFunctionName)
ECR_URI=$(cf_out ECRRepositoryUri)
APPRUNNER_ECR_ROLE=$(cf_out AppRunnerECRRoleArn)
APPRUNNER_INSTANCE_ROLE=$(cf_out AppRunnerInstanceRoleArn)

echo "  Bedrock KB Role  : $BEDROCK_KB_ROLE"
echo "  SageMaker Role   : $SAGEMAKER_ROLE"
echo "  Lambda Function  : $LAMBDA_FUNCTION"
echo "  ECR URI          : $ECR_URI"

# ── [2/10] Upload FAQ files ──────────────────────────────────────────────────
echo ""
echo "=== [2/10] Uploading FAQ files ==="
aws "${PROFILE_ARG[@]}" s3 sync "$REPO_DIR/data/faqs/" "s3://$DATA_BUCKET/" --region "$REGION"
COUNT=$(aws "${PROFILE_ARG[@]}" s3 ls "s3://$DATA_BUCKET/" --region "$REGION" | wc -l | tr -d ' ')
echo "  $COUNT file(s) in s3://$DATA_BUCKET/"

aws "${PROFILE_ARG[@]}" s3api put-object \
  --bucket "$FEEDBACK_BUCKET" --key "output/" --region "$REGION" > /dev/null
echo "  output/ prefix created in $FEEDBACK_BUCKET"

# ── [3/10] S3 Vector bucket + index ──────────────────────────────────────────
echo ""
echo "=== [3/10] Creating S3 Vector bucket and index ==="
VECTOR_BUCKET_ARN="arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/edu-s3-vector"
VECTOR_INDEX_ARN="arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/edu-s3-vector/index/edu-s3-vector-index"

python3 - <<PYEOF
import boto3, os, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
s3v = session.client("s3vectors")
try:
    s3v.create_vector_bucket(vectorBucketName="edu-s3-vector")
    print("  Vector bucket created.")
except s3v.exceptions.ConflictException:
    print("  Vector bucket already exists.")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr); sys.exit(1)

try:
    s3v.create_index(vectorBucketName="edu-s3-vector", indexName="edu-s3-vector-index",
                     dataType="float32", dimension=1024, distanceMetric="cosine")
    print("  Vector index created.")
except s3v.exceptions.ConflictException:
    print("  Vector index already exists.")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF

# Grant KB role access to the specific vector resources
aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "bedrock-kb-role-${SUFFIX}" \
  --policy-name S3VectorsBucketAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [
        \"s3vectors:PutVectors\",\"s3vectors:GetVectors\",
        \"s3vectors:QueryVectors\",\"s3vectors:DeleteVectors\",
        \"s3vectors:ListVectors\",\"s3vectors:GetIndex\",
        \"s3vectors:GetVectorBucket\"
      ],
      \"Resource\": [\"$VECTOR_BUCKET_ARN\", \"$VECTOR_INDEX_ARN\"]
    }]
  }" > /dev/null
echo "  IAM vector policy updated."

# ── [4/10] Bedrock Knowledge Base ────────────────────────────────────────────
echo ""
echo "=== [4/10] Creating Bedrock Knowledge Base ==="
KB_ID=$(python3 - <<PYEOF
import boto3, os, time, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock-agent")

kbs = bedrock.list_knowledge_bases().get("knowledgeBaseSummaries", [])
for kb in kbs:
    if kb["name"] == "faqs-kb-$SUFFIX":
        print(kb["knowledgeBaseId"]); sys.exit(0)

try:
    kb = bedrock.create_knowledge_base(
        name="faqs-kb-$SUFFIX",
        roleArn="$BEDROCK_KB_ROLE",
        knowledgeBaseConfiguration={
            "type": "VECTOR",
            "vectorKnowledgeBaseConfiguration": {
                "embeddingModelArn": "arn:aws:bedrock:$REGION::foundation-model/amazon.titan-embed-text-v2:0",
                "embeddingModelConfiguration": {
                    "bedrockEmbeddingModelConfiguration": {"dimensions": 1024}
                }
            }
        },
        storageConfiguration={
            "type": "S3_VECTORS",
            "s3VectorsConfiguration": {
                "vectorBucketArn": "$VECTOR_BUCKET_ARN",
                "indexArn": "$VECTOR_INDEX_ARN"
            }
        }
    )
    kb_id = kb["knowledgeBase"]["knowledgeBaseId"]
    print(f"  KB created: {kb_id}", file=sys.stderr)
    for _ in range(36):
        status = bedrock.get_knowledge_base(knowledgeBaseId=kb_id)["knowledgeBase"]["status"]
        if status == "ACTIVE": break
        if status == "FAILED":
            print("KB FAILED", file=sys.stderr); sys.exit(1)
        time.sleep(5)
    print(kb_id)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
)
echo "  Knowledge Base ID: $KB_ID"

# ── [5/10] Data source + sync ────────────────────────────────────────────────
echo ""
echo "=== [5/10] Creating data source and syncing FAQs ==="
DS_ID=$(python3 - <<PYEOF
import boto3, os, time, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock-agent")
KB_ID, DATA_BUCKET = "$KB_ID", "$DATA_BUCKET"

dss = bedrock.list_data_sources(knowledgeBaseId=KB_ID).get("dataSourceSummaries", [])
if dss:
    ds_id = dss[0]["dataSourceId"]
    print(f"  Data source already exists: {ds_id}", file=sys.stderr)
else:
    ds = bedrock.create_data_source(
        knowledgeBaseId=KB_ID,
        name="faqs-ds-$SUFFIX",
        dataSourceConfiguration={
            "type": "S3",
            "s3Configuration": {"bucketArn": f"arn:aws:s3:::{DATA_BUCKET}"}
        },
        vectorIngestionConfiguration={
            "chunkingConfiguration": {
                "chunkingStrategy": "FIXED_SIZE",
                "fixedSizeChunkingConfiguration": {"maxTokens": 300, "overlapPercentage": 20}
            }
        }
    )
    ds_id = ds["dataSource"]["dataSourceId"]
    print(f"  Data source created: {ds_id}", file=sys.stderr)

job = bedrock.start_ingestion_job(knowledgeBaseId=KB_ID, dataSourceId=ds_id)
job_id = job["ingestionJob"]["ingestionJobId"]
print(f"  Ingestion job started: {job_id}", file=sys.stderr)
for _ in range(60):
    resp = bedrock.get_ingestion_job(knowledgeBaseId=KB_ID, dataSourceId=ds_id, ingestionJobId=job_id)
    job_info = resp["ingestionJob"]
    status = job_info["status"]
    if status in ("COMPLETE","FAILED","STOPPED"):
        stats = job_info.get("statistics", {})
        indexed = stats.get("numberOfNewDocumentsIndexed", 0)
        failed  = stats.get("numberOfDocumentsFailed", 0)
        print(f"  Ingestion {status}: indexed={indexed} failed={failed}", file=sys.stderr)
        if status != "COMPLETE" or failed > 0: sys.exit(1)
        break
    time.sleep(5)
print(ds_id)
PYEOF
)
echo "  Data Source ID: $DS_ID"

# ── [6/10] Patch Lambda env vars + IAM ───────────────────────────────────────
echo ""
echo "=== [6/10] Patching Lambda env vars and IAM permissions ==="
aws "${PROFILE_ARG[@]}" lambda update-function-configuration \
  --function-name "$LAMBDA_FUNCTION" \
  --environment "Variables={DATA_BUCKET=$DATA_BUCKET,KNOWLEDGE_BASE_ID=$KB_ID,DATA_SOURCE_ID=$DS_ID}" \
  --region "$REGION" > /dev/null
echo "  Lambda env updated: KB=$KB_ID  DS=$DS_ID"

# Ensure Lambda role has bedrock:StartIngestionJob permission
aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "a2i-lambda-role-${SUFFIX}" \
  --policy-name BedrockIngestionAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [
        \"bedrock:StartIngestionJob\",
        \"bedrock:GetIngestionJob\"
      ],
      \"Resource\": \"arn:aws:bedrock:${REGION}:${ACCOUNT_ID}:knowledge-base/${KB_ID}\"
    }]
  }" > /dev/null
echo "  Lambda IAM: bedrock:StartIngestionJob permission added."

# ── [7/10] SageMaker worker task template ────────────────────────────────────
echo ""
echo "=== [7/10] Creating SageMaker worker task template ==="
TEMPLATE_ARN=$(python3 - <<PYEOF
import boto3, os, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
sm = session.client("sagemaker")
ui_name = "faq-review-ui-$SUFFIX"
try:
    r = sm.describe_human_task_ui(HumanTaskUiName=ui_name)
    print(r["HumanTaskUiArn"])
except sm.exceptions.ResourceNotFound:
    template = open("$REPO_DIR/infra/a2i_worker_template.xml").read()
    r = sm.create_human_task_ui(HumanTaskUiName=ui_name, UiTemplate={"Content": template})
    print(r["HumanTaskUiArn"])
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF
)
echo "  Worker template ARN: $TEMPLATE_ARN"

# ── [8/10] Bedrock Guardrail ─────────────────────────────────────────────────
echo ""
echo "=== [8/10] Creating Bedrock Guardrail ==="
GUARDRAIL_INFO=$(python3 - <<PYEOF
import boto3, os, json, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock")

# Check if guardrail already exists
gs = bedrock.list_guardrails().get("guardrails", [])
existing = next((g for g in gs if g["name"] == "$GUARDRAIL_NAME"), None)
if existing:
    print(f"  Guardrail already exists: {existing['id']}", file=sys.stderr)
    versions = bedrock.list_guardrail_versions(guardrailIdentifier=existing["id"]).get("guardrails", [])
    published = [v for v in versions if v.get("version", "") != "DRAFT"]
    ver = published[-1]["version"] if published else "DRAFT"
    print(json.dumps({"id": existing["id"], "version": ver}))
    sys.exit(0)

# Create guardrail with content filters, denied topics, and contextual grounding
g = bedrock.create_guardrail(
    name="$GUARDRAIL_NAME",
    description="Content safety + anti-hallucination + topic filtering for Leumi Trade support",
    topicPolicyConfig={
        "topicsConfig": [
            {
                "name": "Competitors",
                "definition": "Asking how to use eToro, Plus500, Robinhood, or Interactive Brokers apps.",
                "examples": ["How do I open an eToro account?"],
                "type": "DENY"
            }
        ]
    },
    contentPolicyConfig={
        "filtersConfig": [
            {"type": "HATE",        "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "INSULTS",     "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "SEXUAL",      "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "VIOLENCE",    "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "MISCONDUCT",  "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "PROMPT_ATTACK", "inputStrength": "NONE", "outputStrength": "NONE"},
        ]
    },
    contextualGroundingPolicyConfig={
        "filtersConfig": [
            {"type": "GROUNDING",  "threshold": 0.3},
            {"type": "RELEVANCE",  "threshold": 0.3},
        ]
    },
    blockedInputMessaging="This question is outside Leumi Trade support scope.",
    blockedOutputsMessaging="Unable to generate a reliable answer. Contact Leumi Trade support.",
)
guardrail_id = g["guardrailId"]
print(f"  Guardrail created: {guardrail_id}", file=sys.stderr)

# Publish a version
v = bedrock.create_guardrail_version(guardrailIdentifier=guardrail_id, description="v1")
version = v["version"]
print(f"  Version published: {version}", file=sys.stderr)
print(json.dumps({"id": guardrail_id, "version": version}))
PYEOF
)
GUARDRAIL_ID=$(echo "$GUARDRAIL_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
GUARDRAIL_VERSION=$(echo "$GUARDRAIL_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")
echo "  Guardrail: $GUARDRAIL_ID  version: $GUARDRAIL_VERSION"

# ── [9/10] Build Docker image and push to ECR ────────────────────────────────
echo ""
echo "=== [9/10] Building and pushing Docker image ==="
ECR_REGISTRY="${ECR_URI%%/*}"
aws "${PROFILE_ARG[@]}" ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# --platform linux/amd64 is required when building on Apple Silicon (M1/M2/M3 Macs)
docker build --platform linux/amd64 -t "multi-agent-app-${SUFFIX}" "$REPO_DIR"
docker tag "multi-agent-app-${SUFFIX}:latest" "$ECR_URI:latest"
docker push "$ECR_URI:latest"
echo "  Pushed: $ECR_URI:latest"

# ── [10/10] Create or update App Runner service ──────────────────────────────
echo ""
echo "=== [10/10] Deploying App Runner service ==="

FLOW_ARN="arn:aws:sagemaker:${REGION}:${ACCOUNT_ID}:flow-definition/escalation-review-workflow-${SUFFIX}"
SERVICE_NAME="multi-agent-app-${SUFFIX}"

ENV_JSON=$(python3 - <<PYEOF
import json
print(json.dumps({
    "REGION": "$REGION",
    "KNOWLEDGE_BASE_ID": "$KB_ID",
    "DATA_SOURCE_ID": "$DS_ID",
    "DATA_BUCKET": "$DATA_BUCKET",
    "FEEDBACK_BUCKET": "$FEEDBACK_BUCKET",
    "FLOW_ARN": "$FLOW_ARN",
    "GUARDRAIL_ID": "$GUARDRAIL_ID",
    "GUARDRAIL_VERSION": "$GUARDRAIL_VERSION",
}))
PYEOF
)

SOURCE_CONFIG=$(python3 - <<PYEOF
import json
cfg = {
    "ImageRepository": {
        "ImageIdentifier": "$ECR_URI:latest",
        "ImageRepositoryType": "ECR",
        "ImageConfiguration": {
            "Port": "8080",
            "RuntimeEnvironmentVariables": json.loads(r"""$ENV_JSON""")
        }
    },
    "AuthenticationConfiguration": {"AccessRoleArn": "$APPRUNNER_ECR_ROLE"}
}
print(json.dumps(cfg))
PYEOF
)

EXISTING=$(aws "${PROFILE_ARG[@]}" apprunner list-services --region "$REGION" \
  --query "ServiceSummaryList[?ServiceName=='$SERVICE_NAME'].ServiceArn" \
  --output text 2>/dev/null || true)

if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  echo "  Updating existing service..."
  aws "${PROFILE_ARG[@]}" apprunner update-service \
    --service-arn "$EXISTING" \
    --source-configuration "$SOURCE_CONFIG" \
    --region "$REGION" > /dev/null
  SERVICE_URL=$(aws "${PROFILE_ARG[@]}" apprunner describe-service \
    --service-arn "$EXISTING" --region "$REGION" \
    --query "Service.ServiceUrl" --output text)
else
  echo "  Creating new service..."
  aws "${PROFILE_ARG[@]}" apprunner create-service \
    --service-name "$SERVICE_NAME" \
    --source-configuration "$SOURCE_CONFIG" \
    --instance-configuration "{\"InstanceRoleArn\":\"$APPRUNNER_INSTANCE_ROLE\"}" \
    --health-check-configuration '{"Protocol":"HTTP","Path":"/health","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}' \
    --region "$REGION" > /dev/null

  # Wait for the service to appear then read the URL
  SERVICE_URL=$(aws "${PROFILE_ARG[@]}" apprunner list-services --region "$REGION" \
    --query "ServiceSummaryList[?ServiceName=='$SERVICE_NAME'].ServiceUrl" \
    --output text)
fi

echo ""
echo "==================================================="
echo " DEPLOYMENT COMPLETE"
echo "==================================================="
echo " Region          : $REGION"
echo " Stack           : $STACK_NAME"
echo " Data bucket     : $DATA_BUCKET"
echo " Feedback bucket : $FEEDBACK_BUCKET"
echo " Knowledge Base  : $KB_ID"
echo " Data Source     : $DS_ID"
echo " Lambda          : $LAMBDA_FUNCTION"
echo " Guardrail       : $GUARDRAIL_ID v$GUARDRAIL_VERSION"
echo " ECR             : $ECR_URI:latest"
echo " App Runner URL  : https://$SERVICE_URL"
echo ""
echo " ONE MANUAL STEP — SageMaker A2I (console, once per account):"
echo ""
echo "    1. SageMaker > Ground Truth > Labeling workforces > Private"
echo "       Create team 'HumanReviewTeam', add reviewer email(s)"
echo ""
echo "    2. SageMaker > Augmented AI > Human review workflows > Create"
echo "         Name      : escalation-review-workflow-${SUFFIX}"
echo "         S3 output : s3://${FEEDBACK_BUCKET}/output/"
echo "         IAM role  : ${SAGEMAKER_ROLE}"
echo "         Template  : faq-review-ui-${SUFFIX}"
echo "         Workforce : HumanReviewTeam"
echo ""
echo " Test:"
echo "   curl -s -X POST https://$SERVICE_URL/ask \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"question\":\"Does Leumi Trade support IPO investments?\"}' | jq"
echo ""
echo " Destroy:"
echo "   bash scripts/destroy.sh --stack $STACK_NAME --suffix $SUFFIX --region $REGION --profile ${PROFILE:-default}"
echo "==================================================="
