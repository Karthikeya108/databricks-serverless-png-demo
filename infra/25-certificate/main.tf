# Publicly trusted wildcard certificate for the internal services (*.<domain>), imported into ACM for the internal ALB.
#
# A publicly trusted certificate keeps the setup simple: every client trusts it without extra CA configuration.
# Issuer: Let's Encrypt, DNS-01 challenge via DuckDNS (TXT record). DuckDNS holds one TXT value per name, so the
# certificate covers the wildcard only (no apex), which is all the services need.
#
# The DuckDNS token is read from the DUCKDNS_TOKEN environment variable only (never in HCL, tfvars or state):
#   (set -a; . ~/.config/pngdemo/duckdns.env; set +a; terraform apply)
# The certificate private key IS in the local (gitignored) state. Renewal: re-run apply within 30 days of expiry.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region  = "eu-central-1"
  profile = "pngdemo-sandbox"
  default_tags {
    tags = { project = "pngdemo", stack = "25-certificate", Owner = var.owner }
  }
}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "owner" {
  type = string
}

locals {
  domain = yamldecode(file("${path.module}/../../services.yaml")).domain
}

resource "tls_private_key" "acme_account" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

# No email address: Let's Encrypt doesn't require one (and no longer sends expiry mails).
resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
}

resource "acme_certificate" "wildcard" {
  account_key_pem       = acme_registration.this.account_key_pem
  common_name           = "*.${local.domain}"
  key_type              = "2048"
  min_days_remaining    = 30
  recursive_nameservers = ["1.1.1.1:53", "8.8.8.8:53"]

  dns_challenge {
    provider = "duckdns" # credentials: DUCKDNS_TOKEN environment variable
  }
}

resource "aws_acm_certificate" "wildcard" {
  private_key       = acme_certificate.wildcard.private_key_pem
  certificate_body  = acme_certificate.wildcard.certificate_pem
  certificate_chain = acme_certificate.wildcard.issuer_pem
  tags              = { Name = "pngdemo-wildcard" }

  lifecycle {
    create_before_destroy = true
  }
}

output "acm_certificate_arn" {
  value = aws_acm_certificate.wildcard.arn
}

output "certificate" {
  value = {
    common_name = acme_certificate.wildcard.certificate_domain
    not_after   = acme_certificate.wildcard.certificate_not_after
  }
}
