variable "project_id" {
  description = "Public Cloud project ID (the service_name that owns the Object Storage)."
  type        = string
}

variable "storage_region" {
  description = "Object Storage region, upper-case."
  type        = string
  default     = "CA-EAST-TOR"
}

variable "vps_service_name" {
  description = "Service name of the existing mail VPS (vps-xxxxxxxx.vps.ovh.ca)."
  type        = string
}
