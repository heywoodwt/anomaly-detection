# DS5220 Data Project 1 - Graduate Questions

## Technical Challenges

The greatest challenge in translating from CloudFormation to Terraform was handling the circular dependency between the S3 bucket notification and the SNS topic policy. In CloudFormation, the `DependsOn` attribute and the way `AWS::S3::Bucket` embeds its `NotificationConfiguration` inline means the dependency chain is somewhat implicit. In Terraform, the S3 bucket notification must be split into a separate `aws_s3_bucket_notification` resource (rather than being part of the bucket definition), and it requires an explicit `depends_on` reference to the SNS topic policy so that S3 has permission to publish to the topic before the notification is created. Getting this ordering wrong causes the `aws_s3_bucket_notification` to fail with an access-denied error.

## Access Permissions

The element that grants SNS permission to send HTTP messages to the API is the **SNS Topic Policy** resource.

**Cloud Formation:** `submit/build.yaml`, the `SNSTopicPolicy` resource. This `AWS::SNS::TopicPolicy` contains a policy statement with `Effect: Allow`, `Principal: { Service: s3.amazonaws.com }`, and `Action: sns:Publish`. However, the permission for SNS to *deliver* to the HTTP endpoint is inherent to the SNS subscription itself once the subscription is confirmed (via the `/notify` endpoint responding to the `SubscriptionConfirmation` request), SNS is authorized to POST to that endpoint. There is no separate IAM policy needed for SNS-to-HTTP delivery; the confirmation handshake *is* the authorization mechanism.

**Terraform:** `submit/main.tf`, the `aws_sns_topic_policy.allow_s3` resource serves the same purpose for the S3-to-SNS link. The SNS-to-HTTP delivery is again authorized by the subscription confirmation handshake in `app.py` at the `/notify` endpoint.

## Event Flow and Reliability

**Path of a CSV file:**

1. A CSV file is uploaded to `s3://BUCKET/raw/sensors_YYYYMMDDTHHMMSS.csv`
2. The S3 bucket notification (configured with prefix `raw/` and suffix `.csv`) fires an event to the SNS topic `ds5220-dp1`
3. SNS delivers an HTTP POST to `http://<Elastic-IP>:8000/notify` with the S3 event wrapped in an SNS notification envelope
4. The FastAPI `/notify` endpoint parses the SNS message, extracts the S3 object key, and dispatches `process_file()` as a background task
5. `process_file()` downloads the raw CSV from S3, updates the rolling baseline, runs IsolationForest + z-score detection, and writes the scored CSV to `processed/`, the summary JSON, and the updated baseline back to S3

**If the EC2 instance is down or `/notify` returns an error:**

SNS has a built-in retry policy for HTTP/HTTPS endpoints. For HTTP subscriptions, SNS will attempt delivery with an exponential backoff: 3 retries immediately, then 12 retries at increasing intervals, for a total of up to 23 hours of retries by default. If all retries are exhausted, the message is discarded (unless a dead-letter queue is configured).

**Potential Improvements:**

Configure an **SQS dead-letter queue (DLQ)** on the SNS subscription so failed messages are preserved for later reprocessing rather than lost. Switch from HTTP to **HTTPS** for the SNS subscription endpoint (with a proper TLS certificate) to encrypt data in transit. Use an **SQS queue** as an intermediary between SNS and the application (SNS -> SQS -> application polling) so messages are durably stored even if the application is temporarily unavailable. Add a **health check and auto-restart** mechanism (e.g., systemd service) so the FastAPI process recovers automatically from crashes.

## IAM and Least Privilege

| Operation | Where Used |
|-----------|-----------|
| `s3:GetObject` | Downloading raw CSV files, loading `baseline.json`, reading processed CSVs and summary JSONs in query endpoints |
| `s3:PutObject` | Writing scored CSVs to `processed/`, saving `baseline.json`, writing summary JSONs, uploading the log file |
| `s3:ListBucket` | Paginating through `processed/` prefix to find recent files (via `list_objects_v2`) |


```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::BUCKET_NAME"
    }
  ]
}
```

This replaces the `s3:*` wildcard with only the three operations actually used. It removes permissions for `DeleteObject`, `DeleteBucket`, bucket policy modifications, and all other S3 actions that the application never needs, significantly reducing the damage if the instance is compromised.

## Architecture and Scaling

The current single-instance architecture would bottleneck at the CPU (IsolationForest fitting) and at the sequential baseline updates. To scale:

**Decouple ingestion from processing:** Replace the direct SNS-to-HTTP push with an **SQS queue** (SNS -> SQS). Multiple worker instances can poll the queue, and SQS provides automatic load balancing, visibility timeouts, and retry semantics.
**Auto Scaling Group:** Replace the single EC2 instance with an ASG behind the SQS queue. Workers scale horizontally based on queue depth. Each worker pulls messages, processes files, and deletes messages when done.

With multiple instances, concurrent read-modify-write cycles on `baseline.json` in S3 create a race condition. Two workers could read the same baseline, update it with different batches, and the last writer wins losing the other's updates. Solutions include:

**DynamoDB for state:** Store the baseline in DynamoDB with conditional writes (optimistic locking via version numbers). Failed writes retry with the latest state.

**Single-writer pattern:** Designate one instance or a Lambda function as the baseline updater, and fan out only the detection work.

**Eventual consistency acceptance:** If slight statistical drift is acceptable, each worker could maintain a local baseline and periodically merge, trading accuracy for throughput.

The current design prioritizes simplicity a single instance, in-memory processing, and S3 as the sole data store. Scaling introduces operational complexity (SQS, ASG, DynamoDB), cost, and the need to reason about distributed state. For many real-world sensor pipelines, the SQS + ASG + DynamoDB approach is the standard pattern, but the current architecture is perfectly adequate for moderate throughput (a few files per minute).