# scripts/refresh-bundle.sh writes terraform/spiffe-bundle-keys/key-N.pem.
# Reading the directory removes the "did you remember to pass the
# variable" failure mode that would otherwise register
# agentic-iam.tf's OAuth resource server profile with zero public_keys
# and no error.
locals {
  spiffe_bundle_pem_paths = length(var.spiffe_bundle_pem_paths) > 0 ? var.spiffe_bundle_pem_paths : sort(tolist(fileset(path.module, "spiffe-bundle-keys/*.pem")))
}

check "spiffe_bundle_present" {
  assert {
    condition     = length(local.spiffe_bundle_pem_paths) > 0
    error_message = "terraform/spiffe-bundle-keys/ is empty -- run scripts/refresh-bundle.sh before applying vault-config.tf / agentic-iam.tf."
  }
}
