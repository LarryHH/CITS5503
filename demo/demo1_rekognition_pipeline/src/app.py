import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import unquote_plus

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

_rekognition = None
_table = None


def _dependencies():
    """Create AWS clients once, then reuse them across warm Lambda invocations."""
    global _rekognition, _table
    if _rekognition is None:
        _rekognition = boto3.client("rekognition")
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _rekognition, _table


def _json_default(value):
    # DynamoDB returns Decimal values, which Python's JSON encoder cannot handle.
    if isinstance(value, Decimal):
        return float(value)
    raise TypeError(f"Cannot serialise {type(value).__name__}")


def _bounding_box(box):
    """Store Rekognition's 0-to-1 coordinates for any image dimensions."""
    # DynamoDB supports Decimal but rejects Python float values.
    return {
        field.lower(): Decimal(str(round(box.get(field, 0), 6)))
        for field in ("Left", "Top", "Width", "Height")
    }


def lambda_handler(event, context):
    """Process uploaded images and persist Rekognition analysis results."""
    records = event.get("Records", []) if isinstance(event, dict) else []
    if not records:
        raise ValueError("The event does not contain any S3 records")

    rekognition, table = _dependencies()
    minimum_confidence = float(os.environ.get("MIN_CONFIDENCE", "70"))
    processed = []

    for record in records:
        bucket = record["s3"]["bucket"]["name"]
        # S3 event keys are URL encoded (for example, spaces appear as '+').
        key = unquote_plus(record["s3"]["object"]["key"])

        if key.endswith("/"):
            LOGGER.info("Skipping folder marker s3://%s/%s", bucket, key)
            continue

        # Each method below calls a different pretrained Rekognition capability.
        # No computer-vision model is trained or hosted by this application.
        result = rekognition.detect_labels(
            Image={"S3Object": {"Bucket": bucket, "Name": key}},
            MaxLabels=10,
            MinConfidence=minimum_confidence,
        )

        labels = [
            {
                "name": label["Name"],
                "confidence": Decimal(str(round(label["Confidence"], 2))),
            }
            for label in result.get("Labels", [])
        ]
        faces = rekognition.detect_faces(
            Image={"S3Object": {"Bucket": bucket, "Name": key}},
            Attributes=["ALL"],
        )
        face_boxes = [
            {"bounding_box": _bounding_box(face.get("BoundingBox", {}))}
            for face in faces.get("FaceDetails", [])
        ]
        face_analysis = []
        for face in faces.get("FaceDetails", []):
            analysis = {
                "bounding_box": _bounding_box(face.get("BoundingBox", {})),
                "emotions": [
                    {
                        "type": emotion["Type"],
                        "confidence": Decimal(
                            str(round(emotion["Confidence"], 2))
                        ),
                    }
                    for emotion in sorted(
                        face.get("Emotions", []),
                        key=lambda emotion: emotion["Confidence"],
                        reverse=True,
                    )
                ],
            }
            age_range = face.get("AgeRange", {})
            if "Low" in age_range and "High" in age_range:
                analysis["age_range"] = {
                    "low": age_range["Low"],
                    "high": age_range["High"],
                }
            gender = face.get("Gender", {}).get("Value")
            if gender:
                analysis["gender"] = gender
            face_analysis.append(analysis)
        text = rekognition.detect_text(
            Image={"S3Object": {"Bucket": bucket, "Name": key}}
        )
        text_detections = [
            {
                "text": detection["DetectedText"],
                "type": detection["Type"],
                "confidence": Decimal(str(round(detection["Confidence"], 2))),
                "bounding_box": _bounding_box(detection.get("Geometry", {}).get("BoundingBox", {})),
            }
            for detection in text.get("TextDetections", [])
            # LINE results are easier to display than each individual WORD result.
            if detection.get("Type") == "LINE"
        ]
        celebrities = rekognition.recognize_celebrities(
            Image={"S3Object": {"Bucket": bucket, "Name": key}}
        )
        celebrity_matches = [
            {
                "name": celebrity["Name"],
                "match_confidence": Decimal(
                    str(round(celebrity["MatchConfidence"], 2))
                ),
                "bounding_box": _bounding_box(
                    celebrity.get("Face", {}).get("BoundingBox", {})
                ),
            }
            for celebrity in celebrities.get("CelebrityFaces", [])
        ]

        item = {
            "image_key": key,
            "bucket": bucket,
            "labels": labels,
            "face_count": len(faces.get("FaceDetails", [])),
            "face_boxes": face_boxes,
            "face_analysis": face_analysis,
            "text_detections": text_detections,
            "celebrity_matches": celebrity_matches,
            "processed_at": datetime.now(timezone.utc).isoformat(),
        }
        etag = record["s3"]["object"].get("eTag")
        if etag:
            item["etag"] = etag

        # image_key is the table's partition key, so uploading the same key again
        # replaces its previous analysis rather than creating a duplicate row.
        table.put_item(Item=item)
        processed.append(
            {
                "bucket": bucket,
                "key": key,
                "labels": labels,
                "face_count": item["face_count"],
                "face_boxes": face_boxes,
                "face_analysis": face_analysis,
                "text_detections": text_detections,
                "celebrity_matches": celebrity_matches,
            }
        )
        LOGGER.info("analysis_complete %s", json.dumps(processed[-1], default=_json_default))

    return {"processed": processed}
