# =============================================================================
# providers.tf — Terraform provider configuration
# Token is read from LINODE_TOKEN environment variable — never hardcode it.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# The Linode provider reads LINODE_TOKEN from the environment automatically.
# Run: export LINODE_TOKEN="your_token_here"
provider "linode" {
  # token = var.linode_token   # Uncomment only if not using env var
}
