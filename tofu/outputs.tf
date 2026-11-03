output "buckets" {
  value = { for k, b in ovh_cloud_storage_object_bucket.this : k => b.name }
}

output "vps_display_name" {
  value = data.ovh_vps.mail.displayname
}

# Same shape as satsuma/secrets/restic_s3_env.age and the state backend env.
#   tofu output -raw s3_env_backup | agenix -e restic_s3_env.age
output "s3_env_backup" {
  sensitive = true
  value     = <<-EOT
    AWS_ACCESS_KEY_ID=${ovh_cloud_project_user_s3_credential.s3["backup"].access_key_id}
    AWS_SECRET_ACCESS_KEY=${ovh_cloud_project_user_s3_credential.s3["backup"].secret_access_key}
  EOT
}

output "s3_env_state" {
  sensitive = true
  value     = <<-EOT
    AWS_ACCESS_KEY_ID=${ovh_cloud_project_user_s3_credential.s3["state"].access_key_id}
    AWS_SECRET_ACCESS_KEY=${ovh_cloud_project_user_s3_credential.s3["state"].secret_access_key}
  EOT
}
