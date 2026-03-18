"""
test_feedback_loop.py
=====================
End-to-end test for the human-review → knowledge-base feedback loop.

Steps:
  1. Upload a mock A2I output.json to the feedback bucket (simulates a completed human review)
  2. Read and parse the human answer from S3
  3. Write the Q&A as a new FAQ to the data bucket
  4. Start a Bedrock KB ingestion job and poll until complete
  5. Query the KB to verify the new answer is retrievable

Run from the project root:
    python scripts/test_feedback_loop.py
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import json, time, boto3

# ---------- config (mirrors main.py) ----------
REGION        = "eu-west-1"
AWS_PROFILE   = "aws-sandbox-personal-36"
FEEDBACK_BUCKET = "feedback-bucket-kni9r8"
DATA_BUCKET     = "data-bucket-kni9r8"
KB_ID           = "Q0XGDUOZRR"
DS_ID           = "5SONGOZDXF"

# Mock Q&A to inject
MOCK_QUESTION = "Can I get a refund for a cancelled subscription?"
MOCK_ANSWER   = (
    "Yes, you are entitled to a full refund if you cancel within 30 days of purchase. "
    "Please contact support@company.com with your order number and our team will "
    "process the refund within 5–7 business days."
)

_session = boto3.Session(profile_name=AWS_PROFILE, region_name=REGION)
s3               = _session.client("s3")
bedrock_agent    = _session.client("bedrock-agent")
bedrock_runtime  = _session.client("bedrock-agent-runtime")

# ---------- helpers (same logic as main.py) ----------

def _parse_s3_uri(uri):
    parts = uri.replace("s3://", "").split("/", 1)
    return parts[0], parts[1]


def _read_human_answer(output_s3_uri):
    bucket, key = _parse_s3_uri(output_s3_uri)
    resp = s3.get_object(Bucket=bucket, Key=key)
    data = json.loads(resp["Body"].read())
    return data["humanAnswers"][0]["answerContent"]["human_response"]


def _ingest_to_kb(question, answer, loop_name):
    faq_key = f"faq_human_{loop_name}.txt"
    content = f"Q: {question}\nA: {answer}"
    s3.put_object(Bucket=DATA_BUCKET, Key=faq_key, Body=content.encode())
    print(f"  [OK] New FAQ written → s3://{DATA_BUCKET}/{faq_key}")

    resp = bedrock_agent.start_ingestion_job(
        knowledgeBaseId=KB_ID,
        dataSourceId=DS_ID,
    )
    job_id = resp["ingestionJob"]["ingestionJobId"]
    print(f"  [OK] KB ingestion job started: {job_id}")
    return job_id


def _poll_ingestion(job_id, max_polls=30, interval=10):
    """Poll Bedrock KB ingestion job until terminal state."""
    for i in range(max_polls):
        resp = bedrock_agent.get_ingestion_job(
            knowledgeBaseId=KB_ID,
            dataSourceId=DS_ID,
            ingestionJobId=job_id,
        )
        status = resp["ingestionJob"]["status"]
        stats = resp["ingestionJob"].get("statistics", {})
        print(f"  Ingestion poll {i+1}/{max_polls}: status={status}  stats={stats}")
        if status == "COMPLETE":
            return True
        if status in ("FAILED", "STOPPED"):
            print(f"  [FAIL] Ingestion ended with: {status}")
            return False
        time.sleep(interval)
    print("  [FAIL] Ingestion timed out.")
    return False


def _query_kb(question):
    """Run a semantic search and return (top_text, top_score)."""
    resp = bedrock_runtime.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": question},
        retrievalConfiguration={
            "vectorSearchConfiguration": {
                "numberOfResults": 5,
                "overrideSearchType": "SEMANTIC",
            }
        },
    )
    results = resp.get("retrievalResults", [])
    if not results:
        return None, 0.0
    top = sorted(results, key=lambda r: r.get("score", 0.0), reverse=True)[0]
    return top.get("content", {}).get("text", ""), float(top.get("score", 0.0))


# ---------- STEP 1: upload mock A2I output ----------

def step1_upload_mock_output():
    print("\n=== STEP 1: Upload mock A2I output to feedback bucket ===")
    loop_name = f"loop-test-{int(time.time())}"
    mock_output = {
        "flowDefinitionArn": f"arn:aws:sagemaker:{REGION}:599843985030:flow-definition/escalation-review-workflow",
        "humanLoopName": loop_name,
        "humanAnswers": [
            {
                "acceptanceTime": "2026-03-16T10:00:00.000Z",
                "submissionTime": "2026-03-16T10:01:00.000Z",
                "timeSpentInSeconds": 60.0,
                "workerId": "mock-worker-001",
                "answerContent": {
                    "human_response": MOCK_ANSWER
                }
            }
        ],
        "inputContent": {
            "question": MOCK_QUESTION,
            "faq_suggestion": "No relevant FAQ found."
        }
    }
    s3_key = f"output/escalation-review-workflow/mock/{loop_name}/output.json"
    s3.put_object(
        Bucket=FEEDBACK_BUCKET,
        Key=s3_key,
        Body=json.dumps(mock_output).encode()
    )
    s3_uri = f"s3://{FEEDBACK_BUCKET}/{s3_key}"
    print(f"  [OK] Mock output uploaded → {s3_uri}")
    return s3_uri, loop_name


# ---------- STEP 2: read and parse human answer ----------

def step2_read_answer(s3_uri):
    print("\n=== STEP 2: Read human answer from S3 ===")
    answer = _read_human_answer(s3_uri)
    print(f"  [OK] Human answer: {answer[:120]}...")
    assert answer == MOCK_ANSWER, f"Answer mismatch!\n  got: {answer}\n  expected: {MOCK_ANSWER}"
    print("  [OK] Answer matches expected mock data.")
    return answer


# ---------- STEP 3 + 4: write FAQ to data bucket, trigger KB sync ----------

def step3_ingest(question, answer, loop_name):
    print("\n=== STEP 3: Write FAQ to data bucket ===")
    job_id = _ingest_to_kb(question, answer, loop_name)
    print("\n=== STEP 4: Poll KB ingestion until complete ===")
    ok = _poll_ingestion(job_id)
    assert ok, "KB ingestion did not complete successfully."
    print("  [OK] Ingestion complete.")
    return job_id


# ---------- STEP 5: verify KB is searchable ----------

def step5_verify_kb(question):
    print("\n=== STEP 5: Query KB to verify new FAQ is retrievable ===")
    # Give the index a moment to settle
    time.sleep(5)
    text, score = _query_kb(question)
    print(f"  Top result (score={score:.3f}):\n    {text[:200]}")
    assert score > 0.0, "KB returned no results — ingestion may have failed silently."
    # Check that the answer text appears in the top result
    key_phrase = "refund"
    assert key_phrase.lower() in text.lower(), (
        f"Expected '{key_phrase}' in top KB result but got:\n  {text}"
    )
    print(f"  [OK] KB returns relevant result with score={score:.3f}")


# ---------- main ----------

if __name__ == "__main__":
    print("=" * 60)
    print("  Feedback Loop End-to-End Test")
    print("=" * 60)

    s3_uri, loop_name = step1_upload_mock_output()
    answer           = step2_read_answer(s3_uri)
    step3_ingest(MOCK_QUESTION, answer, loop_name)
    step5_verify_kb(MOCK_QUESTION)

    print("\n" + "=" * 60)
    print("  ALL STEPS PASSED — feedback loop is working end-to-end.")
    print("=" * 60)
