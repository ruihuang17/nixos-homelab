# The mail VPS is read, not managed. The ovh_vps resource places a paid order
# on create, and the provider maintainers plan to rework it (issue #1126), so
# importing it risks a replace plan. Switch to an import block once the
# resource is reworked or `-generate-config-out` produces a clean plan.
data "ovh_vps" "mail" {
  service_name = var.vps_service_name
}
