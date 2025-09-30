# Main resources: IAM, launch template, ASG, (optional ALB), scheduled rotation Lambda/Rule, CloudWatch Log group.

provider "aws" {
  # region configured by caller or environment
}

# Resolve latest Amazon Linux 2023 AMI (x86_64, EBS-backed)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["137112412989"] # Amazon
  filter {
    name   = "name"
    values = ["amzn-ami-*-2023-*", "al2023-ami-*", "amazon-linux-2023*"] # best-effort; adapt region naming if needed
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# IAM role for EC2 instances (SSM + CloudWatch agent + basic)
resource "aws_iam_role" "instance_role" {
  name               = "${var.asg_name}-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Attach managed policies: SSM, CloudWatch Agent
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Instance profile
resource "aws_iam_instance_profile" "instance_profile" {
  name = "${var.asg_name}-instance-profile"
  role = aws_iam_role.instance_role.name
}

# CloudWatch Log Group for /var/log/messages
resource "aws_cloudwatch_log_group" "instance_logs" {
  name              = "/aws/ephemeral/${var.asg_name}/messages"
  retention_in_days = 30
  tags              = var.tags
}

# Security Group for instances (private) - allow inbound from ALB SG (if ALB is created) or from nothing (SSM uses Agent via SSM)
resource "aws_security_group" "instance_sg" {
  name        = "${var.asg_name}-instance-sg"
  description = "Security group for ASG instances (private)"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

# If ALB will be created, create ALB SG that allows inbound TLS/HTTP from 0.0.0.0/0
resource "aws_security_group" "alb_sg" {
  count       = var.create_alb ? 1 : 0
  name        = "${var.asg_name}-alb-sg"
  description = "ALB security group"
  vpc_id      = var.vpc_id
  tags        = var.tags

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    description = "Allow TLS"
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    description = "Allow HTTP"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# Allow ALB to talk to instances on port 80
resource "aws_security_group_rule" "alb_to_instances" {
  count                    = var.create_alb ? 1 : 0
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  description              = "Allow ALB to reach Nginx"
  security_group_id        = aws_security_group.instance_sg.id
  source_security_group_id = aws_security_group.alb_sg[0].id
}

# Egress: instances can talk out
resource "aws_security_group_rule" "instances_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.instance_sg.id
  cidr_blocks       = ["0.0.0.0/0"]
  ipv6_cidr_blocks  = ["::/0"]
}

# Launch template with user_data to install nginx, CloudWatch agent config and start it
resource "aws_launch_template" "lt" {
  name_prefix   = "${var.asg_name}-lt-"
  image_id      = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type
  iam_instance_profile {
    name = aws_iam_instance_profile.instance_profile.name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance_sg.id]
  }

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    cloudwatch_log_group = aws_cloudwatch_log_group.instance_logs.name
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, { "Name" = var.asg_name })
  }

  # Additional launch template configuration can be added (block device mapping, etc.)
}

# ASG
resource "aws_autoscaling_group" "asg" {
  name                      = var.asg_name
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.desired_capacity
  vpc_zone_identifier       = var.private_subnet_ids
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }
  # health checks - let ASG use ELB health checks if ALB is created
  health_check_type        = var.create_alb ? "ELB" : "EC2"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = var.asg_name
    propagate_at_launch = true
  }

  tag {
    key                 = "managed-by"
    value               = "terraform"
    propagate_at_launch = true
  }
}

# Instance Refresh initial config (used if you want to trigger immediate refresh from Terraform)
resource "aws_autoscaling_group" "asg_refresh_stub" {
  # This is a placeholder demonstrating Terraform's instance_refresh support.
  # The real scheduled refresh is implemented via the lambda + eventbridge below.
  # NOTE: Many users prefer external trigger; keep Terraform-managed refresh minimal.
  count = 0
}

# ----------- Optional ALB (bonus) -----------
resource "aws_lb" "alb" {
  count               = var.create_alb ? 1 : 0
  name                = "${var.asg_name}-alb"
  internal            = false
  load_balancer_type  = "application"
  security_groups     = [aws_security_group.alb_sg[0].id]
  subnets             = var.public_subnet_ids
  tags                = var.tags
}

resource "aws_lb_target_group" "tg" {
  count    = var.create_alb ? 1 : 0
  name     = "${var.asg_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }
  tags = var.tags
}

resource "aws_lb_listener" "https" {
  count = var.create_alb ? 1 : 0
  load_balancer_arn = aws_lb.alb[0].arn
  port              = 443
  protocol          = "HTTPS"

  ssl_policy       = "ELBSecurityPolicy-2016-08"
  certificate_arn  = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg[0].arn
  }
}

resource "aws_lb_listener" "http" {
  count = var.create_alb ? 0 : 0
  # Optional: create HTTP listener redirect -> HTTPS if you want
}

# Attach ASG to target group
resource "aws_autoscaling_attachment" "asg_tg_attachment" {
  count              = var.create_alb ? 1 : 0
  autoscaling_group_name = aws_autoscaling_group.asg.name
  lb_target_group_arn     = aws_lb_target_group.tg[0].arn
}

# Output ALB DNS name
output "alb_dns_name" {
  value       = var.create_alb ? aws_lb.alb[0].dns_name : ""
  description = "ALB DNS name (if created)"
}

# ----------- Scheduled rotation (EventBridge rule -> Lambda that calls StartInstanceRefresh) -----------
# Lambda role
resource "aws_iam_role" "lambda_role" {
  name               = "${var.asg_name}-refresh-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Lambda inline policy allowing StartInstanceRefresh and CloudWatch logs
resource "aws_iam_policy" "lambda_policy" {
  name        = "${var.asg_name}-lambda-policy"
  description = "Allows calling autoscaling:StartInstanceRefresh and logs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:StartInstanceRefresh",
          "autoscaling:DescribeAutoScalingGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_iam_role_policy_attachment" "lambda_basic_exec" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda function that starts instance refresh for this ASG
resource "aws_lambda_function" "refresh_lambda" {
  filename         = "${path.module}/lambda/refresh_lambda.zip" # we'll package source into zip; or use source_code_hash below
  function_name    = "${var.asg_name}-start-instance-refresh"
  handler          = "refresh_lambda.lambda_handler"
  runtime          = "python3.10"
  role             = aws_iam_role.lambda_role.arn
  source_code_hash = filebase64sha256("${path.module}/lambda/refresh_lambda.zip")
  timeout          = 30
  tags             = var.tags
}

# EventBridge rule to schedule daily/periodic refresh
resource "aws_cloudwatch_event_rule" "rotation_schedule" {
  name                = "${var.asg_name}-rotation-schedule"
  description         = "Schedules automatic ASG instance refresh every ${var.rotate_days} days"
  schedule_expression = "rate(${var.rotate_days} days)"
}

resource "aws_cloudwatch_event_target" "rule_target" {
  rule      = aws_cloudwatch_event_rule.rotation_schedule.name
  target_id = "StartInstanceRefresh"
  arn       = aws_lambda_function.refresh_lambda.arn
  input     = jsonencode({ "AutoScalingGroupName" = aws_autoscaling_group.asg.name })
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.refresh_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotation_schedule.arn
}

# Helper random id (used to create zip file name, etc.)
resource "random_pet" "id" {
  length = 2
}
