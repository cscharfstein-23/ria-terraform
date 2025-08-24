# terraform {
#   cloud {
#     organization = "cayo-org"
#     workspaces {
#       name = "TEST"
#     }
#   }
# }

terraform {
  required_providers {
    turbonomic = {
      source  = "IBM/turbonomic"
      version = "1.0.2"
    }
    aws = {
      source = "hashicorp/aws"
      version = "6.0.0-beta2"
    }
  }
}

provider "turbonomic" {
  username   = var.turbonomic_username
  password   = var.turbonomic_password
  hostname   = var.turbonomic_hostname
  skipverify = true
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

resource "tls_private_key" "rsa" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
# dynamically create SSH Key
resource "aws_key_pair" "ssh_key" {
  key_name   = "ssh_key"
  public_key = tls_private_key.rsa.public_key_openssh
}
# Use default VPC
data "aws_vpc" "default" {
  default = true
}

# Find the latest Ubuntu 22.04 AMI
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_security_group" "allow_access" {
  name        = "${var.instance_name}-sg"
  description = "Allow SSH, HTTP and Kubernetes API access"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = {
      ssh  = 22
      k8s  = 6443
      web  = 80
      ssl  = 443
      hcm = 55671
      snmp = 161
      snmp_trap = 162
    }

    content {
      description = ingress.key
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.ssh_allowed_cidrs
    }
  }

  # # NodePort-Range für Kubernetes (30000–32767)
  # ingress {
  #   description = "k8s-nodeport-range"
  #   from_port   = 30000
  #   to_port     = 32767
  #   protocol    = "tcp"
  #   cidr_blocks = var.ssh_allowed_cidrs
  # }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
data "turbonomic_cloud_entity_recommendation" "example" {
  entity_name = var.instance_name
  entity_type = "VirtualMachine"
}

# EC2 instance
resource "aws_instance" "my_ec2_instance" {
key_name                    = "ssh_key"
  ami                    = data.aws_ami.ubuntu.id
  # instance_type          = var.instance_type
  instance_type = (
    data.turbonomic_cloud_entity_recommendation.example.new_instance_type != null
    ? data.turbonomic_cloud_entity_recommendation.example.new_instance_type
    : var.instance_type
  )

  key_name               = aws_key_pair.ssh_key.key_name
  vpc_security_group_ids = [aws_security_group.allow_access.id]

  root_block_device {
    volume_size = var.root_disk_size
    volume_type = "gp3"
  }

  tags = {
    Name = var.instance_name
  }
}


# Output SSH Key für weitere verwendung (Vault etc.) 
output "ssh_key" {
  value  = tls_private_key.rsa.private_key_pem

}
# Output public IP
output "instance_ip" {
  description = "Die öffentliche IP-Adresse der EC2-Instanz"
  value       = aws_instance.my_ec2_instance.public_ip
}
