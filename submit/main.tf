# DS5220 Data Project 1 - Terraform
# Event-driven anomaly detection pipeline.
# Provisions EC2, S3, SNS, IAM, Security Group, and Elastic IP.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}


variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "ssh_location" {
  description = "CIDR block allowed to SSH into the instance (your IP/32)"
  type        = string
  default     = "98.124.196.77/32"
}

# Look up the latest Ubuntu 24.04 LTS AMI from Canonical
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_s3_bucket" "app_bucket" {
  force_destroy = false
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.app_bucket.id

  topic {
    topic_arn     = aws_sns_topic.ds5220_dp1.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sns_topic_policy.allow_s3]
}

resource "aws_sns_topic" "ds5220_dp1" {
  name = "ds5220-dp1"
}

resource "aws_sns_topic_policy" "allow_s3" {
  arn = aws_sns_topic.ds5220_dp1.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3Publish"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.ds5220_dp1.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.app_bucket.arn
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "http_notify" {
  topic_arn              = aws_sns_topic.ds5220_dp1.arn
  protocol               = "http"
  endpoint               = "http://${aws_eip.app_eip.public_ip}:8000/notify"
  endpoint_auto_confirms = false

  depends_on = [aws_eip_association.eip_assoc]
}


resource "aws_security_group" "app_sg" {
  name        = "anomaly-detection-sg"
  description = "Allow SSH from my IP and API from anywhere"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_location]
  }

  ingress {
    description = "FastAPI"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_iam_role" "ec2_role" {
  name = "anomaly-detection-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "S3BucketFullAccess"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = [
          aws_s3_bucket.app_bucket.arn,
          "${aws_s3_bucket.app_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "anomaly-detection-ec2-profile"
  role = aws_iam_role.ec2_role.name
}


resource "aws_instance" "app_instance" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = "t3.micro"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    bucket_name = aws_s3_bucket.app_bucket.id
  }))

  depends_on = [aws_s3_bucket.app_bucket]

  tags = {
    Name = "anomaly-detection"
  }
}


resource "aws_eip" "app_eip" {
  domain = "vpc"
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.app_instance.id
  allocation_id = aws_eip.app_eip.id
}

output "bucket_name" {
  description = "S3 bucket for the anomaly detection pipeline"
  value       = aws_s3_bucket.app_bucket.id
}

output "elastic_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_eip.app_eip.public_ip
}

output "api_endpoint" {
  description = "Base URL for the FastAPI application"
  value       = "http://${aws_eip.app_eip.public_ip}:8000"
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic"
  value       = aws_sns_topic.ds5220_dp1.arn
}