import os
import json
import boto3
from botocore.exceptions import ClientError
from datetime import datetime

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['DYNAMODB_TABLE'])
s3 = boto3.client('s3')

def lambda_handler(event, context):
    for record in event['Records']:
        try:
            message = json.loads(record['body'])
            print(f"Processing message: {message}")
            
            # Validate message structure - now requiring UploadTimestamp too
            required_fields = ['ImageID', 'S3Key', 'UploadTimestamp']
            if not all(k in message for k in required_fields):
                raise ValueError(f"Invalid message format. Required fields: {required_fields}")
            
            # Create the full key for DynamoDB operations
            item_key = {
                'ImageID': message['ImageID'],
                'UploadTimestamp': int(message['UploadTimestamp'])
            }
            
            # Update DynamoDB status
            table.update_item(
                Key=item_key,
                UpdateExpression="SET #status = :status, #lastUpdated = :now",
                ExpressionAttributeNames={
                    '#status': 'Status',
                    '#lastUpdated': 'LastUpdated'
                },
                ExpressionAttributeValues={
                    ':status': 'PROCESSING',
                    ':now': datetime.now().isoformat()
                }
            )
            
            # Add your actual processing logic here
            # Example: Generate thumbnail
            # s3.download_file(...)
            # process_image(...)
            # s3.upload_file(...)
            
            # Mark as completed
            table.update_item(
                Key=item_key,
                UpdateExpression="SET #status = :status, #lastUpdated = :now",
                ExpressionAttributeNames={
                    '#status': 'Status',
                    '#lastUpdated': 'LastUpdated'
                },
                ExpressionAttributeValues={
                    ':status': 'COMPLETED',
                    ':now': datetime.now().isoformat()
                }
            )
            
        except Exception as e:
            print(f"Error processing message: {str(e)}")
            # Update DynamoDB with error status (if we have the key)
            if 'message' in locals() and 'ImageID' in message:
                table.update_item(
                    Key={
                        'ImageID': message['ImageID'],
                        'UploadTimestamp': int(message.get('UploadTimestamp', 0))
                    },
                    UpdateExpression="SET #status = :status, #error = :error, #lastUpdated = :now",
                    ExpressionAttributeNames={
                        '#status': 'Status',
                        '#error': 'Error',
                        '#lastUpdated': 'LastUpdated'
                    },
                    ExpressionAttributeValues={
                        ':status': 'FAILED',
                        ':error': str(e),
                        ':now': datetime.now().isoformat()
                    }
                )
            raise  # This will trigger SQS retry