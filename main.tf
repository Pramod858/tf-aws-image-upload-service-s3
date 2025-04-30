############################
# Data Sources
############################
data "aws_s3_bucket" "static_website" {
  bucket = var.static_bucket_name
}

data "aws_s3_bucket" "uploads" {
  bucket = var.uploads_bucket_name
}

data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

data "archive_file" "lambda_presigned" {
  type        = "zip"
  source_file = "${path.module}/lambda/presigned_url.py"
  output_path = "${path.module}/lambda/presigned_url.zip"
}

data "archive_file" "lambda_process" {
  type        = "zip"
  source_file = "${path.module}/lambda/image_processor.py"
  output_path = "${path.module}/lambda/image_processor.zip"
}

############################
# S3 Resources
############################
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = data.aws_s3_bucket.uploads.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST", "HEAD"]
    allowed_origins = ["https://${var.app_domain_name}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_website_configuration" "static_website" {
  bucket = data.aws_s3_bucket.static_website.id
  index_document { suffix = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "static_website" {
  bucket = data.aws_s3_bucket.static_website.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "static_website" {
  bucket = data.aws_s3_bucket.static_website.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicReadGetObject",
      Effect    = "Allow",
      Principal = "*",
      Action    = "s3:GetObject",
      Resource  = "${data.aws_s3_bucket.static_website.arn}/*"
    }]
  })
}

############################
# DynamoDB Table
############################
resource "aws_dynamodb_table" "image_metadata" {
  name           = var.dynamodb_table_name
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "ImageID"
  range_key      = "UploadTimestamp"

  attribute {
    name = "ImageID"
    type = "S"
  }

  attribute {
    name = "UploadTimestamp"
    type = "N"
  }

  ttl {
    attribute_name = "TimeToLive"
    enabled        = false # Set to true if you want TTL
  }

  tags = { Environment = "production" }
}

############################
# SQS Resources
############################
resource "aws_sqs_queue" "image_processing_dlq" {
  name = "${var.sqs_queue_name}-dlq"
}

resource "aws_sqs_queue" "image_processing" {
  name                      = var.sqs_queue_name
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400
  receive_wait_time_seconds = 10
  visibility_timeout_seconds = 120

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.image_processing_dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Environment = "production" }
}

############################
# IAM Resources
############################
resource "aws_iam_role" "lambda_exec" {
  name = "lambda_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "lambda_s3_access" {
  name        = "lambda-s3-access-policy"
  description = "Policy for Lambda functions"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:PutObject", "s3:PutObjectAcl"],
        Resource = "${data.aws_s3_bucket.uploads.arn}/*"
      },
      {
        Effect   = "Allow",
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"],
        Resource = aws_dynamodb_table.image_metadata.arn
      },
      {
        Effect   = "Allow",
        Action   = [
          "sqs:SendMessage", "sqs:ReceiveMessage", 
          "sqs:DeleteMessage", "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ],
        Resource = [
          aws_sqs_queue.image_processing.arn,
          aws_sqs_queue.image_processing_dlq.arn
        ]
      },
      {
        Effect   = "Allow",
        Action   = "logs:CreateLogGroup",
        Resource = "arn:aws:logs:${var.region}:*:*"
      },
      {
        Effect   = "Allow",
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"],
        Resource = [
          "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/${var.lambda_function_name}:*",
          "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/${var.lambda_function_name_2}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_access.arn
}

############################
# Lambda Functions
############################
resource "aws_lambda_function" "presigned_url_generator" {
  filename         = data.archive_file.lambda_presigned.output_path
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_exec.arn
  handler          = "presigned_url.lambda_handler"
  runtime          = "python3.9"
  timeout          = 30
  memory_size      = 128
  source_code_hash = data.archive_file.lambda_presigned.output_base64sha256

  environment {
    variables = {
      UPLOAD_BUCKET    = data.aws_s3_bucket.uploads.id
      ALLOWED_ORIGIN   = "https://${var.app_domain_name}"
      DYNAMODB_TABLE   = aws_dynamodb_table.image_metadata.name
      SQS_QUEUE_URL    = aws_sqs_queue.image_processing.url
    }
  }
}

resource "aws_lambda_function" "image_processor" {
  filename         = data.archive_file.lambda_process.output_path
  function_name    = "image-processor"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "image_processor.lambda_handler"
  runtime          = "python3.9"
  timeout          = 60
  memory_size      = 256
  source_code_hash = data.archive_file.lambda_process.output_base64sha256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.image_metadata.name
      UPLOAD_BUCKET  = data.aws_s3_bucket.uploads.id
    }
  }
}

resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_sqs_queue.image_processing.arn
  function_name    = aws_lambda_function.image_processor.arn
  batch_size       = 1
  enabled          = true
  maximum_batching_window_in_seconds = 0
}

############################
# API Gateway
############################
resource "aws_api_gateway_rest_api" "upload_api" {
  name        = var.api_gateway_name
  description = "API for generating S3 presigned URLs"
  endpoint_configuration { types = ["REGIONAL"] }
}

resource "aws_api_gateway_resource" "upload_resource" {
  rest_api_id = aws_api_gateway_rest_api.upload_api.id
  parent_id   = aws_api_gateway_rest_api.upload_api.root_resource_id
  path_part   = "upload"
}

resource "aws_api_gateway_method" "upload_method" {
  rest_api_id   = aws_api_gateway_rest_api.upload_api.id
  resource_id   = aws_api_gateway_resource.upload_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.upload_api.id
  resource_id             = aws_api_gateway_resource.upload_resource.id
  http_method             = aws_api_gateway_method.upload_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.presigned_url_generator.invoke_arn
}

resource "aws_api_gateway_method" "options_method" {
  rest_api_id   = aws_api_gateway_rest_api.upload_api.id
  resource_id   = aws_api_gateway_resource.upload_resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_integration" {
  rest_api_id = aws_api_gateway_rest_api.upload_api.id
  resource_id = aws_api_gateway_resource.upload_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "options_200" {
  rest_api_id = aws_api_gateway_rest_api.upload_api.id
  resource_id = aws_api_gateway_resource.upload_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
  response_models = { "application/json" = "Empty" }
}

resource "aws_api_gateway_integration_response" "options_integration_response" {
  rest_api_id = aws_api_gateway_rest_api.upload_api.id
  resource_id = aws_api_gateway_resource.upload_resource.id
  http_method = aws_api_gateway_method.options_method.http_method
  status_code = aws_api_gateway_method_response.options_200.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'",
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.upload_api.id
  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration.options_integration
  ]
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.lambda_integration,
      aws_api_gateway_integration.options_integration
    ]))
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "prod" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.upload_api.id
  deployment_id = aws_api_gateway_deployment.deployment.id
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presigned_url_generator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.upload_api.execution_arn}/*/POST/upload"
}

############################
# ACM & Route53
############################
resource "aws_acm_certificate" "cert" {
  domain_name               = var.custom_domain_name
  subject_alternative_names = [var.app_domain_name]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

############################
# API Gateway Custom Domain
############################
resource "aws_api_gateway_domain_name" "custom_domain" {
  domain_name              = var.custom_domain_name
  regional_certificate_arn = aws_acm_certificate.cert.arn
  security_policy          = "TLS_1_2"
  endpoint_configuration { types = ["REGIONAL"] }
  depends_on = [aws_acm_certificate_validation.cert]
}

resource "aws_api_gateway_base_path_mapping" "mapping" {
  api_id      = aws_api_gateway_rest_api.upload_api.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  domain_name = aws_api_gateway_domain_name.custom_domain.domain_name
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = var.custom_domain_name
  type    = "A"
  alias {
    name                   = aws_api_gateway_domain_name.custom_domain.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.custom_domain.regional_zone_id
    evaluate_target_health = false
  }
}

############################
# CloudFront Distribution
############################
resource "aws_cloudfront_distribution" "static_website" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for static website"
  default_root_object = "index.html"
  aliases             = [var.app_domain_name]
  price_class         = "PriceClass_100"

  origin {
    domain_name = aws_s3_bucket_website_configuration.static_website.website_endpoint
    origin_id   = "S3-Website-${data.aws_s3_bucket.static_website.id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-Website-${data.aws_s3_bucket.static_website.id}"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.cert]
}

resource "aws_route53_record" "cloudfront" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = var.app_domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.static_website.domain_name
    zone_id                = aws_cloudfront_distribution.static_website.hosted_zone_id
    evaluate_target_health = false
  }
}