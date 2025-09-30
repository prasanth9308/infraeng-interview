variable "asg_name" {
  description = "Autoscaling group name"
  type        = string
}

variable "load_balancer_url" {
  description = "Load balancer URL (informational). If create_alb=true this module will create an ALB and this will be validated/used."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC id where instances and ALB will be created (ALB public subnets must be public)."
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs where EC2 instances should be launched."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the ALB (only needed when create_alb=true)."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "EC2 instance type for ASG"
  type        = string
  default     = "t3.micro"
}

variable "desired_capacity" {
  type        = number
  description = "Desired capacity for ASG"
  default     = 2
}

variable "min_size" {
  type    = number
  default = 1
}

variable "max_size" {
  type    = number
  default = 3
}

variable "create_alb" {
  description = "Create Application Load Balancer (bonus)."
  type        = bool
  default     = false
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for TLS listener (required if create_alb=true)."
  type        = string
  default     = ""
}

variable "rotate_days" {
  description = "How often to rotate instances (days). A scheduled EventBridge rule will trigger StartInstanceRefresh every X days."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Map of tags to apply to created resources"
  type        = map(string)
  default     = {}
}
