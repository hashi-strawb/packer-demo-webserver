terraform {
  # We're using Terraform Checks
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.2"
    }

    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.82"
    }

    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 1.0"
    }
  }
}

# As this is now a TF module, we can't assume eu-west-2
# So get AZs and region dynamically
data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_region" "current" {}

# Create a VPC
# While we could define each of the required resources manually...
# no need to re-invent the wheel when a really good module exists already

module "vpc" {
  # https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest 
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.18.1"

  name = var.vpc_name
  cidr = "10.0.0.0/16"

  azs            = data.aws_availability_zones.available.names[*]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

# Allow us to easily connect to the EC2 instance with AWS EC2 Connect

data "aws_ip_ranges" "ec2_instance_connect" {
  regions  = [data.aws_region.current.name]
  services = ["ec2_instance_connect"]
}

resource "aws_security_group" "ec2_instance_connect" {
  name        = "ec2_instance_connect"
  description = "Allow EC2 Instance Connect to access this host"

  vpc_id = module.vpc.vpc_id

  ingress {
    from_port        = "22"
    to_port          = "22"
    protocol         = "tcp"
    cidr_blocks      = data.aws_ip_ranges.ec2_instance_connect.cidr_blocks
    ipv6_cidr_blocks = data.aws_ip_ranges.ec2_instance_connect.ipv6_cidr_blocks
  }

  tags = {
    CreateDate = data.aws_ip_ranges.ec2_instance_connect.create_date
    SyncToken  = data.aws_ip_ranges.ec2_instance_connect.sync_token
  }
}

# Allow inbound HTTP access on standard port
# In Production, you'd want to configure SSL etc.
# potentially run behind a load balancer of some kind.
# you know, usual production stuff.
#
# But for this demo, this works fine.
resource "aws_security_group" "inbound_http" {
  name        = "inbound_http"
  description = "Allow inbound HTTP access"

  vpc_id = module.vpc.vpc_id

  ingress {
    from_port        = "80"
    to_port          = "80"
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    from_port        = "443"
    to_port          = "443"
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}



data "tfe_ip_ranges" "addresses" {}

resource "aws_security_group" "outbound_http_tfc" {
  name        = "outbound_http_tfc"
  description = "Allow outbound HTTP access to TFC APIs"

  vpc_id = module.vpc.vpc_id

  egress {
    from_port        = "443"
    to_port          = "443"
    protocol         = "tcp"
    cidr_blocks      = data.tfe_ip_ranges.addresses.api
    ipv6_cidr_blocks = ["::/0"]
  }
}


# Find a suitable AMI to use for this purpose
data "hcp_packer_artifact" "webserver" {
  bucket_name  = var.packer_bucket_name
  channel_name = var.packer_channel
  platform     = "aws"

  region = data.aws_region.current.name
}
check "ami_age" {
  # Deliberately short TTL, to check if Health Checks pick this up
  assert {
    condition     = timecmp(plantimestamp(), timeadd(data.hcp_packer_artifact.webserver.created_at, "720h")) < 0
    error_message = "The image referenced in the Packer bucket is more than 30 days old."
  }
}

# Now create the EC2 instance
resource "aws_instance" "web" {
  ami = data.hcp_packer_artifact.webserver.external_identifier
  tags = {
    "packer_bucket_name" = var.packer_bucket_name
    "packer_channel"     = var.packer_channel
  }

  associate_public_ip_address = true


  instance_type = var.instance_type
  vpc_security_group_ids = [
    aws_security_group.ec2_instance_connect.id,
    aws_security_group.inbound_http.id,
    aws_security_group.outbound_http_tfc.id,
  ]

  subnet_id = module.vpc.public_subnets[0]


  metadata_options {
    // do not force IMDSv2, mainly because I'm lazy and the /identity endpoint currently relies on v1
    http_tokens = "optional"
  }



  lifecycle {
    create_before_destroy = true
  }
}




# And a Route53 Record
data "aws_route53_zone" "zone" {
  name = var.route53_zone
}
resource "aws_route53_record" "webserver" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "${aws_instance.web.id}.${var.vpc_name}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.web.public_ip]
}




locals {
  webserver_url = "http://${aws_route53_record.webserver.fqdn}"
}

check "smoke_test" {
  data "terracurl_request" "test" {
    name   = "smoke test webserver"
    url    = local.webserver_url
    method = "GET"

    response_codes = [
      200
    ]

    // Retry for up to 60s
    max_retry      = 4
    retry_interval = 15
  }

  assert {
    condition     = data.terracurl_request.test.status_code == "200"
    error_message = "${data.terracurl_request.test.url} responded with ${data.terracurl_request.test.status_code}; expected 200"
  }
}


// This part is very specific to my webserver AMI, with its /identity URL
// I'm fine with that for now... but at some point I may want to make this configurable
// e.g. if I add different types of AMIs.
//
// I may also want to add a /health or /status endpoint to check against

check "identity_test" {
  data "terracurl_request" "test_identity" {
    name   = "smoke test webserver identity"
    url    = "${local.webserver_url}/identity"
    method = "GET"

    response_codes = [
      200
    ]

    // Retry for up to 60s
    max_retry      = 4
    retry_interval = 15
  }

  assert {
    condition     = data.terracurl_request.test_identity.status_code == "200"
    error_message = "${data.terracurl_request.test_identity.url} responded with ${data.terracurl_request.test_identity.status_code}; expected 200"
  }
}
