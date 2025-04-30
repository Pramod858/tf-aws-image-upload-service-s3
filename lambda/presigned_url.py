import json
import boto3
import time
from datetime import datetime
import os
import uuid

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
sqs = boto3.client('sqs')

def lambda_handler(event, context):
    try:
        body = json.loads(event['body'])
        filename = body['filename']
        filetype = body['filetype']
        
        if not filetype.startswith('image/'):
            return {
                'statusCode': 400,
                'headers': {
                    'Access-Control-Allow-Origin': os.environ['ALLOWED_ORIGIN'],
                    'Content-Type': 'application/json'
                },
                'body': json.dumps({'error': 'Only images allowed'})
            }
        
        # Generate unique ID and timestamp
        image_id = str(uuid.uuid4())
        timestamp = int(datetime.now().timestamp())
        key = f"uploads/{timestamp}_{filename}"
        
        # Generate presigned URL
        presigned_url = s3.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': os.environ['UPLOAD_BUCKET'],
                'Key': key,
                'ContentType': filetype,
                'ACL': 'private'
            },
            ExpiresIn=300
        )
        
        # Store metadata in DynamoDB
        table = dynamodb.Table(os.environ['DYNAMODB_TABLE'])
        table.put_item(
            Item={
                'ImageID': image_id,
                'UploadTimestamp': timestamp,
                'Filename': filename,
                'FileType': filetype,
                'S3Key': key,
                'Status': 'UPLOADED'
            }
        )
        
        # Send message to SQS for processing
        sqs.send_message(
            QueueUrl=os.environ['SQS_QUEUE_URL'],
            MessageBody=json.dumps({
                'ImageID': image_id,
                'S3Key': key,
                'Filename': filename,
                'UploadTimestamp': int(time.time())
            })
        )
        
        return {
            'statusCode': 200,
            'headers': {
                'Access-Control-Allow-Origin': os.environ['ALLOWED_ORIGIN'],
                'Access-Control-Allow-Methods': 'POST, OPTIONS',
                'Content-Type': 'application/json'
            },
            'body': json.dumps({
                'url': presigned_url,
                'key': key,
                'image_id': image_id
            })
        }
        
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': {
                'Access-Control-Allow-Origin': os.environ['ALLOWED_ORIGIN'],
                'Content-Type': 'application/json'
            },
            'body': json.dumps({'error': str(e)})
        }