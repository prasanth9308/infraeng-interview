output "asg_name" {
  value = aws_autoscaling_group.asg.name
}

output "instance_profile" {
  value = aws_iam_instance_profile.instance_profile.name
}

output "cloudwatch_log_group" {
  value = aws_cloudwatch_log_group.instance_logs.name
}

output "alb_dns" {
  value = var.create_alb ? aws_lb.alb[0].dns_name : ""
}
