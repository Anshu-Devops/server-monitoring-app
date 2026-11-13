
variable "aws_region" {
  description = "AWS deployment region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "server-monitoring-app"
}

variable "app_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "jenkins_instance_type" {
  type    = string
  default = "t3.small"
}

variable "trusted_cidr" {
  description = "Your public IP with /32 mask"
  type        = string
}

variable "public_key_path" {
  description = "Path to locally generated SSH public key"
  type        = string
  default     = "~/.ssh/server-monitoring-key.pub"
}
