import json
import os
import boto3

s3 = boto3.client("s3")
bedrock_agent = boto3.client("bedrock-agent")

DATA_BUCKET = os.environ["DATA_BUCKET"]
KNOWLEDGE_BASE_ID = os.environ["KNOWLEDGE_BASE_ID"]
DATA_SOURCE_ID = os.environ["DATA_SOURCE_ID"]


def handler(event, context):
    detail = event["detail"]
    loop_name = detail["humanLoopName"]
    output_s3_uri = detail["humanLoopOutput"]["outputS3Uri"]

    print(f"Processing completed loop: {loop_name}")
    print(f"Output URI: {output_s3_uri}")

    # Read A2I output from S3
    parts = output_s3_uri.replace("s3://", "").split("/", 1)
    bucket, key = parts[0], parts[1]
    resp = s3.get_object(Bucket=bucket, Key=key)
    data = json.loads(resp["Body"].read())

    question = data["inputContent"]["question"]
    answer = data["humanAnswers"][0]["answerContent"]["human_response"]

    # Write FAQ to data bucket
    faq_key = f"faq_human_{loop_name}.txt"
    content = f"Q: {question}\nA: {answer}"
    s3.put_object(Bucket=DATA_BUCKET, Key=faq_key, Body=content.encode())
    print(f"FAQ written to s3://{DATA_BUCKET}/{faq_key}")

    # Start KB ingestion
    resp = bedrock_agent.start_ingestion_job(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        dataSourceId=DATA_SOURCE_ID,
    )
    job_id = resp["ingestionJob"]["ingestionJobId"]
    print(f"KB ingestion started: {job_id}")

    return {"statusCode": 200, "loopName": loop_name, "ingestionJobId": job_id}
