locals {
  # One bucket and one least-privilege S3 user per entry.
  buckets = {
    backup = {
      name        = "satsuma-backup"
      description = "restic offsite backups from satsuma"
    }
    state = {
      name        = "satsuma-tofu-state"
      description = "OpenTofu remote state"
    }
  }
}

resource "ovh_cloud_storage_object_bucket" "this" {
  for_each = local.buckets

  service_name = var.project_id
  name         = each.value.name
  region       = var.storage_region

  versioning = {
    status = "ENABLED"
  }

  encryption = {
    algorithm = "AES256"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "ovh_cloud_project_user" "s3" {
  for_each = local.buckets

  service_name = var.project_id
  description  = "s3-${each.value.name}: ${each.value.description}"
  role_names   = ["objectstore_operator"]
}

resource "ovh_cloud_project_user_s3_credential" "s3" {
  for_each = local.buckets

  service_name = var.project_id
  user_id      = ovh_cloud_project_user.s3[each.key].id
}

resource "ovh_cloud_project_user_s3_policy" "s3" {
  for_each = local.buckets

  service_name = var.project_id
  user_id      = ovh_cloud_project_user.s3[each.key].id

  policy = jsonencode({
    Statement = [{
      Sid    = "RWContainer"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:ListMultipartUploadParts",
        "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload",
        "s3:GetBucketLocation",
      ]
      Resource = [
        "arn:aws:s3:::${each.value.name}",
        "arn:aws:s3:::${each.value.name}/*",
      ]
    }]
  })
}

# The backup bucket already exists and holds the restic repository.
import {
  to = ovh_cloud_storage_object_bucket.this["backup"]
  id = "${var.project_id}/satsuma-backup"
}
