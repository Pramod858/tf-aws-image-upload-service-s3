############################
# Variables
############################
variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "static_bucket_name" {
  description = "Name for the static website bucket"
  type        = string
  default     = "pramod-public-2"
}

variable "uploads_bucket_name" {
  description = "Name for the uploads bucket"
  type        = string
  default     = "pramod-private"
}

variable "lambda_function_name" {
  description = "Name for the Lambda function"
  type        = string
  default     = "s3-presigned-url-generator"
}

variable "lambda_function_name_2" {
  description = "Name for the Lambda function to Image Processing"
  type        = string
  default     = "image-processing"
}

variable "api_gateway_name" {
  description = "Name for the API Gateway"
  type        = string
  default     = "s3-upload-api"
}

variable "domain_name" {
  description = "Domain name for the static website"
  type        = string
  default     = "pramodpro.xyz"
}

variable "custom_domain_name" {
  description = "Custom domain name for the API Gateway"
  type        = string
  default     = "api.pramodpro.xyz"
}

variable "app_domain_name" {
  description = "Domain name for the application"
  type        = string
  default     = "app.pramodpro.xyz"
  
}

variable "dynamodb_table_name" {
  description = "Name for the DynamoDB table"
  type        = string
  default     = "ImageMetadata"
}

variable "sqs_queue_name" {
  description = "Name for the SQS queue"
  type        = string
  default     = "image-processing-queue"
}