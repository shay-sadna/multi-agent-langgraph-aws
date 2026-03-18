#!/usr/bin/env bash
# ============================================================
# manual_setup.sh — Step-by-step manual deployment
#
# Creates all infrastructure components individually using
# AWS CLI and Python helpers. Useful for learning, debugging,
# or when you want fine-grained control over each step.
#
# Components created:
#   Step 1:  S3 data and feedback buckets
#   Step 2:  IAM roles (KB, SageMaker, Lambda, App Runner)
#   Step 3:  S3 Vector bucket + index (for KB embeddings)
#   Step 4:  Upload FAQ files to S3
#   Step 5:  Bedrock Knowledge Base
#   Step 6:  KB data source + FAQ ingestion
#   Step 7:  Lambda function (A2I completion handler)
#   Step 8:  EventBridge rule (triggers Lambda on A2I completion)
#   Step 9:  SageMaker worker task template
#   Step 10: Bedrock Guardrail
#   Step 11: ECR repository + Docker build + push
#   Step 12: App Runner service
#   Manual:  SageMaker A2I workforce + workflow (console only)
#
# Usage:
#   bash scripts/manual_setup.sh --profile my-aws-profile --suffix abc123
# ============================================================
set -euo pipefail

# ── Configuration — edit these before running ─────────────────────────────────
PROFILE=""
REGION="eu-west-1"
SUFFIX=""      # set with --suffix or will be auto-generated
ACCESS_KEY=""
SECRET_KEY=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)    PROFILE="$2";    shift 2 ;;
    --region)     REGION="$2";     shift 2 ;;
    --suffix)     SUFFIX="$2";     shift 2 ;;
    --access-key) ACCESS_KEY="$2"; shift 2 ;;
    --secret-key) SECRET_KEY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# Generate suffix if not provided
[[ -z "$SUFFIX" ]] && SUFFIX="$(python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase+string.digits,k=6)))")"

# Auth
if [[ -n "$ACCESS_KEY" && -n "$SECRET_KEY" ]]; then
  export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  unset AWS_PROFILE 2>/dev/null || true
  PROFILE_ARG=()
  export BOTO3_PROFILE=""
elif [[ -n "$PROFILE" ]]; then
  PROFILE_ARG=(--profile "$PROFILE")
  export BOTO3_PROFILE="$PROFILE"
else
  echo "ERROR: provide --profile <name> or --access-key + --secret-key"
  exit 1
fi

# Derived names — all suffixed to avoid conflicts between students
DATA_BUCKET="data-bucket-${SUFFIX}"
FEEDBACK_BUCKET="feedback-bucket-${SUFFIX}"
KB_ROLE_NAME="bedrock-kb-role-${SUFFIX}"
SM_ROLE_NAME="sagemaker-a2i-role-${SUFFIX}"
LAMBDA_ROLE_NAME="a2i-lambda-role-${SUFFIX}"
APPRUNNER_ECR_ROLE_NAME="apprunner-ecr-role-${SUFFIX}"
APPRUNNER_INSTANCE_ROLE_NAME="apprunner-instance-role-${SUFFIX}"
LAMBDA_FUNCTION_NAME="a2i-completion-handler-${SUFFIX}"
ECR_REPO_NAME="multi-agent-app-${SUFFIX}"
KB_NAME="faqs-kb-${SUFFIX}"
DS_NAME="faqs-ds-${SUFFIX}"
SERVICE_NAME="multi-agent-app-${SUFFIX}"
GUARDRAIL_NAME="guardrail-${SUFFIX}"

VECTOR_BUCKET="edu-s3-vector"
VECTOR_INDEX="edu-s3-vector-index"

echo "==================================================="
echo " MANUAL SETUP — multi-agent lab"
echo " Region : $REGION | Suffix : $SUFFIX"
echo "==================================================="

# ── Validate credentials ──────────────────────────────────────────────────────
ACCOUNT_ID=$(aws "${PROFILE_ARG[@]}" sts get-caller-identity \
  --query Account --output text --region "$REGION")
VECTOR_BUCKET_ARN="arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}"
VECTOR_INDEX_ARN="arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET}/index/${VECTOR_INDEX}"
echo "  Account: $ACCOUNT_ID  Region: $REGION"

# ── Step 1: S3 Buckets ────────────────────────────────────────────────────────
echo ""
echo "=== [1/12] Creating S3 buckets ==="

# Data bucket — stores FAQ files read by the KB ingestion job
aws "${PROFILE_ARG[@]}" s3 mb "s3://${DATA_BUCKET}" --region "$REGION"
aws "${PROFILE_ARG[@]}" s3api put-bucket-versioning \
  --bucket "$DATA_BUCKET" \
  --versioning-configuration Status=Enabled
aws "${PROFILE_ARG[@]}" s3api put-bucket-encryption \
  --bucket "$DATA_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
echo "  Created: s3://${DATA_BUCKET}"

# Feedback bucket — A2I human review outputs land here
aws "${PROFILE_ARG[@]}" s3 mb "s3://${FEEDBACK_BUCKET}" --region "$REGION"
aws "${PROFILE_ARG[@]}" s3api put-bucket-encryption \
  --bucket "$FEEDBACK_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws "${PROFILE_ARG[@]}" s3api put-object \
  --bucket "$FEEDBACK_BUCKET" --key "output/" --region "$REGION" > /dev/null
echo "  Created: s3://${FEEDBACK_BUCKET}"

# ── Step 2: IAM Roles ─────────────────────────────────────────────────────────
echo ""
echo "=== [2/12] Creating IAM roles ==="

# 2a — Bedrock Knowledge Base role (Bedrock assumes this to read S3 + write S3 Vectors)
aws "${PROFILE_ARG[@]}" iam create-role \
  --role-name "$KB_ROLE_NAME" \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": {\"Service\": \"bedrock.amazonaws.com\"},
      \"Action\": \"sts:AssumeRole\",
      \"Condition\": {\"StringEquals\": {\"aws:SourceAccount\": \"$ACCOUNT_ID\"}}
    }]
  }" > /dev/null

aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$KB_ROLE_NAME" \
  --policy-name EmbeddingModelAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"bedrock:InvokeModel\",
      \"Resource\": \"arn:aws:bedrock:${REGION}::foundation-model/amazon.titan-embed-text-v2:0\"
    }]
  }" > /dev/null

aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$KB_ROLE_NAME" \
  --policy-name S3DataAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\", \"Action\": \"s3:ListBucket\",
       \"Resource\": \"arn:aws:s3:::${DATA_BUCKET}\"},
      {\"Effect\": \"Allow\", \"Action\": \"s3:GetObject\",
       \"Resource\": \"arn:aws:s3:::${DATA_BUCKET}/*\"}
    ]
  }" > /dev/null

aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$KB_ROLE_NAME" \
  --policy-name S3VectorsAccess \
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
KB_ROLE_ARN=$(aws "${PROFILE_ARG[@]}" iam get-role --role-name "$KB_ROLE_NAME" \
  --query Role.Arn --output text)
echo "  Bedrock KB role: $KB_ROLE_ARN"

# 2b — SageMaker A2I role (SageMaker assumes this to write review outputs to S3)
aws "${PROFILE_ARG[@]}" iam create-role \
  --role-name "$SM_ROLE_NAME" \
  --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sagemaker.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null
aws "${PROFILE_ARG[@]}" iam attach-role-policy \
  --role-name "$SM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess
aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$SM_ROLE_NAME" \
  --policy-name FeedbackBucketAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": [\"s3:PutObject\",\"s3:GetObject\",\"s3:ListBucket\"],
      \"Resource\": [
        \"arn:aws:s3:::${FEEDBACK_BUCKET}\",
        \"arn:aws:s3:::${FEEDBACK_BUCKET}/*\"
      ]
    }]
  }" > /dev/null
SM_ROLE_ARN=$(aws "${PROFILE_ARG[@]}" iam get-role --role-name "$SM_ROLE_NAME" \
  --query Role.Arn --output text)
echo "  SageMaker A2I role: $SM_ROLE_ARN"

# 2c — Lambda role (Lambda assumes this to read feedback S3, write to data S3, trigger KB re-ingestion)
aws "${PROFILE_ARG[@]}" iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null
aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name LambdaPermissions \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\",
       \"Action\": [\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],
       \"Resource\": \"*\"},
      {\"Effect\": \"Allow\", \"Action\": \"s3:GetObject\",
       \"Resource\": \"arn:aws:s3:::${FEEDBACK_BUCKET}/*\"},
      {\"Effect\": \"Allow\", \"Action\": \"s3:PutObject\",
       \"Resource\": \"arn:aws:s3:::${DATA_BUCKET}/*\"},
      {\"Effect\": \"Allow\",
       \"Action\": [\"bedrock-agent:StartIngestionJob\",\"bedrock-agent:GetIngestionJob\"],
       \"Resource\": \"*\"}
    ]
  }" > /dev/null
LAMBDA_ROLE_ARN=$(aws "${PROFILE_ARG[@]}" iam get-role --role-name "$LAMBDA_ROLE_NAME" \
  --query Role.Arn --output text)
echo "  Lambda role: $LAMBDA_ROLE_ARN"

# 2d — App Runner ECR access role (build.apprunner.amazonaws.com pulls image from ECR)
aws "${PROFILE_ARG[@]}" iam create-role \
  --role-name "$APPRUNNER_ECR_ROLE_NAME" \
  --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"build.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null
aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$APPRUNNER_ECR_ROLE_NAME" \
  --policy-name ECRPullAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\",
       \"Action\": [\"ecr:GetDownloadUrlForLayer\",\"ecr:BatchGetImage\",
                    \"ecr:BatchCheckLayerAvailability\",\"ecr:DescribeImages\"],
       \"Resource\": \"arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO_NAME}\"},
      {\"Effect\": \"Allow\", \"Action\": \"ecr:GetAuthorizationToken\", \"Resource\": \"*\"}
    ]
  }" > /dev/null
APPRUNNER_ECR_ROLE_ARN=$(aws "${PROFILE_ARG[@]}" iam get-role \
  --role-name "$APPRUNNER_ECR_ROLE_NAME" --query Role.Arn --output text)
echo "  App Runner ECR role: $APPRUNNER_ECR_ROLE_ARN"

# 2e — App Runner instance role (tasks.apprunner.amazonaws.com calls Bedrock, Comprehend, A2I)
aws "${PROFILE_ARG[@]}" iam create-role \
  --role-name "$APPRUNNER_INSTANCE_ROLE_NAME" \
  --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"tasks.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  > /dev/null
aws "${PROFILE_ARG[@]}" iam put-role-policy \
  --role-name "$APPRUNNER_INSTANCE_ROLE_NAME" \
  --policy-name AppPermissions \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {\"Effect\": \"Allow\",
       \"Action\": [\"bedrock:InvokeModel\",\"bedrock:Retrieve\",\"bedrock:RetrieveAndGenerate\",
                    \"bedrock:ApplyGuardrail\",\"bedrock-agent-runtime:Retrieve\",
                    \"bedrock-agent-runtime:RetrieveAndGenerate\"],
       \"Resource\": \"*\"},
      {\"Effect\": \"Allow\", \"Action\": \"comprehend:DetectSentiment\", \"Resource\": \"*\"},
      {\"Effect\": \"Allow\",
       \"Action\": [\"sagemaker:StartHumanLoop\",\"sagemaker-a2i-runtime:StartHumanLoop\",
                    \"sagemaker-a2i-runtime:DescribeHumanLoop\"],
       \"Resource\": \"*\"},
      {\"Effect\": \"Allow\",
       \"Action\": [\"s3:PutObject\",\"s3:GetObject\",\"s3:ListBucket\"],
       \"Resource\": [
         \"arn:aws:s3:::${DATA_BUCKET}\",\"arn:aws:s3:::${DATA_BUCKET}/*\",
         \"arn:aws:s3:::${FEEDBACK_BUCKET}\",\"arn:aws:s3:::${FEEDBACK_BUCKET}/*\"
       ]}
    ]
  }" > /dev/null
APPRUNNER_INSTANCE_ROLE_ARN=$(aws "${PROFILE_ARG[@]}" iam get-role \
  --role-name "$APPRUNNER_INSTANCE_ROLE_NAME" --query Role.Arn --output text)
echo "  App Runner instance role: $APPRUNNER_INSTANCE_ROLE_ARN"

# Wait for IAM propagation before using roles
echo "  Waiting 15s for IAM propagation..."
sleep 15

# ── Step 3: S3 Vector bucket + index ─────────────────────────────────────────
echo ""
echo "=== [3/12] Creating S3 Vector bucket and index ==="
python3 - <<PYEOF
import boto3, os, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
s3v = session.client("s3vectors")

try:
    s3v.create_vector_bucket(vectorBucketName="$VECTOR_BUCKET")
    print("  Vector bucket created: $VECTOR_BUCKET")
except s3v.exceptions.ConflictException:
    print("  Vector bucket already exists: $VECTOR_BUCKET")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr); sys.exit(1)

try:
    s3v.create_index(vectorBucketName="$VECTOR_BUCKET", indexName="$VECTOR_INDEX",
                     dataType="float32", dimension=1024, distanceMetric="cosine")
    print("  Vector index created: $VECTOR_INDEX")
except s3v.exceptions.ConflictException:
    print("  Vector index already exists: $VECTOR_INDEX")
except Exception as e:
    print(f"  ERROR: {e}", file=sys.stderr); sys.exit(1)
PYEOF

# ── Step 4: Upload FAQ files ──────────────────────────────────────────────────
echo ""
echo "=== [4/12] Uploading FAQ files ==="
aws "${PROFILE_ARG[@]}" s3 sync "$REPO_DIR/data/faqs/" "s3://$DATA_BUCKET/" --region "$REGION"
COUNT=$(aws "${PROFILE_ARG[@]}" s3 ls "s3://$DATA_BUCKET/" --region "$REGION" | wc -l | tr -d ' ')
echo "  Uploaded $COUNT FAQ files to s3://$DATA_BUCKET/"

# ── Step 5: Bedrock Knowledge Base ───────────────────────────────────────────
echo ""
echo "=== [5/12] Creating Bedrock Knowledge Base ==="
KB_ID=$(python3 - <<PYEOF
import boto3, os, time, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock-agent")

# Idempotent: return existing KB if name matches
kbs = bedrock.list_knowledge_bases().get("knowledgeBaseSummaries", [])
for kb in kbs:
    if kb["name"] == "$KB_NAME":
        print(f"  KB already exists: {kb['knowledgeBaseId']}", file=sys.stderr)
        print(kb["knowledgeBaseId"]); sys.exit(0)

kb = bedrock.create_knowledge_base(
    name="$KB_NAME",
    roleArn="$KB_ROLE_ARN",
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
print("  Waiting for ACTIVE status...", file=sys.stderr)
for _ in range(36):
    status = bedrock.get_knowledge_base(knowledgeBaseId=kb_id)["knowledgeBase"]["status"]
    if status == "ACTIVE": break
    if status == "FAILED":
        reasons = bedrock.get_knowledge_base(knowledgeBaseId=kb_id)["knowledgeBase"].get("failureReasons","")
        print(f"  KB FAILED: {reasons}", file=sys.stderr); sys.exit(1)
    time.sleep(5)
print(kb_id)
PYEOF
)
echo "  Knowledge Base ID: $KB_ID"

# ── Step 6: Data source + FAQ ingestion ──────────────────────────────────────
echo ""
echo "=== [6/12] Creating data source and ingesting FAQs ==="
DS_ID=$(python3 - <<PYEOF
import boto3, os, time, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock-agent")

dss = bedrock.list_data_sources(knowledgeBaseId="$KB_ID").get("dataSourceSummaries", [])
if dss:
    ds_id = dss[0]["dataSourceId"]
    print(f"  Data source already exists: {ds_id}", file=sys.stderr)
else:
    ds = bedrock.create_data_source(
        knowledgeBaseId="$KB_ID",
        name="$DS_NAME",
        dataSourceConfiguration={
            "type": "S3",
            "s3Configuration": {"bucketArn": "arn:aws:s3:::$DATA_BUCKET"}
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

job = bedrock.start_ingestion_job(knowledgeBaseId="$KB_ID", dataSourceId=ds_id)
job_id = job["ingestionJob"]["ingestionJobId"]
print(f"  Ingestion job started: {job_id}", file=sys.stderr)
print("  Waiting for ingestion to complete...", file=sys.stderr)
for _ in range(60):
    resp = bedrock.get_ingestion_job(knowledgeBaseId="$KB_ID", dataSourceId=ds_id, ingestionJobId=job_id)
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

# ── Step 7: Lambda function ───────────────────────────────────────────────────
echo ""
echo "=== [7/12] Creating Lambda function ==="

# Zip the handler from the lambda/ directory
cd "$REPO_DIR/lambda"
zip -q function.zip a2i_completion_handler.py
cd "$REPO_DIR"

LAMBDA_ARN=$(aws "${PROFILE_ARG[@]}" lambda create-function \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --runtime python3.12 \
  --handler a2i_completion_handler.handler \
  --role "$LAMBDA_ROLE_ARN" \
  --zip-file fileb://"$REPO_DIR/lambda/function.zip" \
  --timeout 60 \
  --environment "Variables={DATA_BUCKET=$DATA_BUCKET,KNOWLEDGE_BASE_ID=$KB_ID,DATA_SOURCE_ID=$DS_ID}" \
  --region "$REGION" \
  --query FunctionArn --output text)

rm -f "$REPO_DIR/lambda/function.zip"
echo "  Lambda function created: $LAMBDA_ARN"

# Wait for Lambda to be active
python3 - <<PYEOF
import boto3, os, time
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
lm = session.client("lambda")
for _ in range(20):
    state = lm.get_function_configuration(FunctionName="$LAMBDA_FUNCTION_NAME")["State"]
    if state == "Active": break
    time.sleep(3)
print("  Lambda is Active.")
PYEOF

# ── Step 8: EventBridge rule ──────────────────────────────────────────────────
echo ""
echo "=== [8/12] Creating EventBridge rule ==="

RULE_ARN=$(aws "${PROFILE_ARG[@]}" events put-rule \
  --name "a2i-completion-rule-${SUFFIX}" \
  --event-pattern '{"source":["aws.sagemaker"],"detail-type":["SageMaker A2I HumanLoop Status Change"],"detail":{"humanLoopStatus":["Completed"]}}' \
  --state ENABLED \
  --region "$REGION" \
  --query RuleArn --output text)
echo "  EventBridge rule ARN: $RULE_ARN"

aws "${PROFILE_ARG[@]}" events put-targets \
  --rule "a2i-completion-rule-${SUFFIX}" \
  --targets "Id=a2i-lambda-target,Arn=$LAMBDA_ARN" \
  --region "$REGION" > /dev/null

aws "${PROFILE_ARG[@]}" lambda add-permission \
  --function-name "$LAMBDA_FUNCTION_NAME" \
  --statement-id "allow-eventbridge-${SUFFIX}" \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "$RULE_ARN" \
  --region "$REGION" > /dev/null
echo "  Lambda permission added for EventBridge."

# ── Step 9: SageMaker worker task template ────────────────────────────────────
echo ""
echo "=== [9/12] Creating SageMaker worker task template ==="
TEMPLATE_ARN=$(python3 - <<PYEOF
import boto3, os, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
sm = session.client("sagemaker")
ui_name = "faq-review-ui-$SUFFIX"
try:
    r = sm.describe_human_task_ui(HumanTaskUiName=ui_name)
    print(f"  Template already exists: {r['HumanTaskUiArn']}", file=sys.stderr)
    print(r["HumanTaskUiArn"])
except sm.exceptions.ResourceNotFound:
    template = open("$REPO_DIR/infra/a2i_worker_template.xml").read()
    r = sm.create_human_task_ui(HumanTaskUiName=ui_name, UiTemplate={"Content": template})
    print(f"  Template created: {r['HumanTaskUiArn']}", file=sys.stderr)
    print(r["HumanTaskUiArn"])
PYEOF
)
echo "  Worker template ARN: $TEMPLATE_ARN"

# ── Step 10: Bedrock Guardrail ────────────────────────────────────────────────
echo ""
echo "=== [10/12] Creating Bedrock Guardrail ==="
GUARDRAIL_INFO=$(python3 - <<PYEOF
import boto3, os, json, sys
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock")

# Check if guardrail already exists
gs = bedrock.list_guardrails().get("guardrails", [])
existing = next((g for g in gs if g["name"] == "$GUARDRAIL_NAME"), None)
if existing:
    print(f"  Guardrail already exists: {existing['id']}", file=sys.stderr)
    versions = bedrock.list_guardrail_versions(guardrailIdentifier=existing["id"]).get("guardrails",[])
    published = [v for v in versions if v.get("version","") != "DRAFT"]
    ver = published[-1]["version"] if published else "DRAFT"
    print(json.dumps({"id": existing["id"], "version": ver}))
    sys.exit(0)

# Create guardrail with content filters + contextual grounding
g = bedrock.create_guardrail(
    name="$GUARDRAIL_NAME",
    description="Content safety + anti-hallucination for multi-agent customer support",
    contentPolicyConfig={
        "filtersConfig": [
            {"type": "HATE",        "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "INSULTS",     "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "SEXUAL",      "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "VIOLENCE",    "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "MISCONDUCT",  "inputStrength": "HIGH", "outputStrength": "HIGH"},
            {"type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE"},
        ]
    },
    contextualGroundingPolicyConfig={
        "filtersConfig": [
            {"type": "GROUNDING",  "threshold": 0.7},
            {"type": "RELEVANCE",  "threshold": 0.7},
        ]
    },
    blockedInputMessaging="I cannot process this input.",
    blockedOutputsMessaging="I wasn't able to generate a reliable answer. Please contact support.",
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

# ── Step 11: ECR + Docker + push ──────────────────────────────────────────────
echo ""
echo "=== [11/12] Creating ECR repo and pushing Docker image ==="
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}"

# Create ECR repository (idempotent)
aws "${PROFILE_ARG[@]}" ecr describe-repositories \
  --repository-names "$ECR_REPO_NAME" --region "$REGION" > /dev/null 2>&1 || \
aws "${PROFILE_ARG[@]}" ecr create-repository \
  --repository-name "$ECR_REPO_NAME" \
  --image-scanning-configuration scanOnPush=true \
  --region "$REGION" > /dev/null
echo "  ECR repository: $ECR_URI"

# Authenticate Docker to ECR
aws "${PROFILE_ARG[@]}" ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Build and push — --platform linux/amd64 required for Apple Silicon (M1/M2/M3)
docker build --platform linux/amd64 -t "$ECR_REPO_NAME" "$REPO_DIR"
docker tag "${ECR_REPO_NAME}:latest" "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"
echo "  Pushed: ${ECR_URI}:latest"

# ── Step 12: App Runner service ───────────────────────────────────────────────
echo ""
echo "=== [12/12] Creating App Runner service ==="

# Detect correct Nova Pro cross-region inference profile for this region
NOVA_MODEL_ID=$(python3 - <<PYEOF
import boto3, os
session = boto3.Session(profile_name=os.environ.get("BOTO3_PROFILE") or None, region_name="$REGION")
bedrock = session.client("bedrock")
profiles = bedrock.list_inference_profiles().get("inferenceProfileSummaries", [])
nova = next((p["inferenceProfileId"] for p in profiles if "nova-pro" in p["inferenceProfileId"]), None)
print(nova if nova else "amazon.nova-pro-v1:0")
PYEOF
)

# FLOW_ARN will be updated after the manual A2I workflow creation step
FLOW_ARN="arn:aws:sagemaker:${REGION}:${ACCOUNT_ID}:flow-definition/escalation-review-workflow-${SUFFIX}"

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
        "ImageIdentifier": "${ECR_URI}:latest",
        "ImageRepositoryType": "ECR",
        "ImageConfiguration": {
            "Port": "8080",
            "RuntimeEnvironmentVariables": json.loads(r"""$ENV_JSON""")
        }
    },
    "AuthenticationConfiguration": {"AccessRoleArn": "$APPRUNNER_ECR_ROLE_ARN"}
}
print(json.dumps(cfg))
PYEOF
)

CREATE_OUT=$(aws "${PROFILE_ARG[@]}" apprunner create-service \
  --service-name "$SERVICE_NAME" \
  --source-configuration "$SOURCE_CONFIG" \
  --instance-configuration "{\"InstanceRoleArn\":\"$APPRUNNER_INSTANCE_ROLE_ARN\"}" \
  --health-check-configuration '{"Protocol":"HTTP","Path":"/health","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}' \
  --region "$REGION")
SERVICE_URL=$(echo "$CREATE_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Service']['ServiceUrl'])")
SERVICE_ARN=$(echo "$CREATE_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Service']['ServiceArn'])")

echo ""
echo "==================================================="
echo " MANUAL SETUP COMPLETE"
echo "==================================================="
echo " Suffix          : $SUFFIX"
echo " Data bucket     : $DATA_BUCKET"
echo " Feedback bucket : $FEEDBACK_BUCKET"
echo " Knowledge Base  : $KB_ID"
echo " Data Source     : $DS_ID"
echo " Lambda          : $LAMBDA_FUNCTION_NAME"
echo " Guardrail       : $GUARDRAIL_ID  (v$GUARDRAIL_VERSION)"
echo " ECR             : ${ECR_URI}:latest"
echo " App Runner URL  : https://$SERVICE_URL"
echo ""
echo " ⚠  REMAINING MANUAL STEP — SageMaker A2I (AWS Console):"
echo ""
echo "    1. SageMaker > Ground Truth > Labeling workforces > Private"
echo "       Create team 'HumanReviewTeam', add reviewer email(s)"
echo "       (Accept the email invitation to set password)"
echo ""
echo "    2. SageMaker > Augmented AI > Human review workflows > Create"
echo "         Name      : escalation-review-workflow-${SUFFIX}"
echo "         S3 output : s3://${FEEDBACK_BUCKET}/output/"
echo "         IAM role  : ${SM_ROLE_ARN}"
echo "         Template  : faq-review-ui-${SUFFIX}"
echo "         Workforce : HumanReviewTeam"
echo ""
echo "    3. Copy the workflow ARN and update App Runner env var:"
echo "       aws apprunner update-service --service-arn $SERVICE_ARN \\"
echo "         --source-configuration '{...\"FLOW_ARN\":\"<paste-arn-here>\"}' \\"
echo "         --region $REGION"
echo "       (Full example in docs/DEPLOYMENT.md)"
echo ""
echo " Test (App Runner starts in ~2 minutes):"
echo "   curl -s -X POST https://$SERVICE_URL/ask \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"question\":\"What is Leumi Trade?\"}' | jq"
echo ""
echo " Destroy:"
echo "   bash scripts/destroy.sh --suffix $SUFFIX --region $REGION --profile ${PROFILE:-default}"
echo "==================================================="
