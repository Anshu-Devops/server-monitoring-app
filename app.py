
from flask import Flask, jsonify
from datetime import datetime, timezone
import os
import platform
import socket
import json
import boto3
from botocore.exceptions import BotoCoreError, ClientError

app = Flask(__name__)

S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "ap-south-1")


@app.route("/")
def home():
    return """
    <h1>DevOps Server Monitoring App</h1>
    <p>Application is running successfully!</p>
    <ul>
        <li><a href="/health">Health Check</a></li>
        <li><a href="/info">Server Information</a></li>
        <li><a href="/report">Generate and Upload S3 Report</a></li>
    </ul>
    """


@app.route("/health")
def health():
    return jsonify({
        "status": "UP",
        "timestamp": datetime.now(timezone.utc).isoformat()
    })


@app.route("/info")
def info():
    return jsonify({
        "hostname": socket.gethostname(),
        "operating_system": platform.system(),
        "python_version": platform.python_version(),
        "timestamp": datetime.now(timezone.utc).isoformat()
    })


@app.route("/report")
def report():
    if not S3_BUCKET:
        return jsonify({
            "error": "S3_BUCKET environment variable is not configured"
        }), 500

    report_data = {
        "application": "server-monitoring-app",
        "hostname": socket.gethostname(),
        "status": "UP",
        "generated_at": datetime.now(timezone.utc).isoformat()
    }

    filename = (
        "health-reports/"
        + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        + ".json"
    )

    try:
        s3 = boto3.client("s3", region_name=AWS_REGION)

        s3.put_object(
            Bucket=S3_BUCKET,
            Key=filename,
            Body=json.dumps(report_data, indent=2),
            ContentType="application/json"
        )

        return jsonify({
            "message": "Report uploaded successfully",
            "bucket": S3_BUCKET,
            "object_key": filename,
            "report": report_data
        })

    except (BotoCoreError, ClientError):
        app.logger.exception("S3 upload failed")
        return jsonify({
            "error": "Could not upload report to S3"
        }), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
