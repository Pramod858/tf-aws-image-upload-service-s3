############################
# Outputs
############################
output "static_website_url" {
  value = aws_s3_bucket_website_configuration.static_website.website_endpoint
}

output "api_gateway_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}/upload"
}

output "uploads_bucket_name" {
  value = data.aws_s3_bucket.uploads.id
}