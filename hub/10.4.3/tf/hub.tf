
/***************************
 * Hub Load Balancer       *
 **************************/

# Allow inbound TCP from the internet to control-plane nodes.
resource "google_compute_firewall" "hub-public" {
  name    = "${var.env_name}-hub-public"
  network = "${var.env_name}-pcf-network"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["control"]
}

# Allow GCP health-check probers to reach control-plane nodes.
# Source ranges are the fixed GCP health-check and proxy IP blocks.
resource "google_compute_firewall" "hub-health-check" {
  name    = "${var.env_name}-hub-health-check"
  network = "${var.env_name}-pcf-network"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["control"]
}

# Global static IP — required by global TCP proxy forwarding rules.
# NOTE: the address will change from the old regional IP; DNS is
# updated automatically because the record references this resource.
resource "google_compute_global_address" "hub" {
  name = "${var.env_name}-hub"
}

# Single TCP health check on port 443.
resource "google_compute_health_check" "hub" {
  name                = "${var.env_name}-hub"
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = 443
  }
}

# Unmanaged instance groups — one per AZ.
# Terraform creates these empty; the BOSH GCP CPI adds/removes VM
# instances at deploy time via:
#   vm_extension cloud_properties: { backend_service: <name> }
# lifecycle.ignore_changes prevents Terraform from clearing membership
# that BOSH manages between applies.
locals {
  control_zones = ["${var.region}-a", "${var.region}-b", "${var.region}-c"]
}

resource "google_compute_instance_group" "hub" {
  for_each = toset(local.control_zones)

  name    = "${var.env_name}-hub-${each.key}"
  zone    = each.key
  network = "projects/${var.project_id}/global/networks/${var.env_name}-pcf-network"

  named_port {
    name = "https"
    port = 443
  }

  lifecycle {
    ignore_changes = [instances]
  }
}

# Single backend service. Both the port-80 and port-443 forwarding
# rules proxy through here; the TCP proxy connects to the backend on
# port 443 in both cases. HTTP clients that hit port 80 are served by
# contour-envoy's HTTP listener (contour redirects to HTTPS internally).
resource "google_compute_backend_service" "hub" {
  name                  = "${var.env_name}-hub"
  protocol              = "TCP"
  port_name             = "https"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_health_check.hub.id]

  dynamic "backend" {
    for_each = google_compute_instance_group.hub
    content {
      group = backend.value.id
    }
  }
}

# Single target TCP proxy — both forwarding rules share it.
resource "google_compute_target_tcp_proxy" "hub" {
  name            = "${var.env_name}-hub"
  backend_service = google_compute_backend_service.hub.id
}

# Global forwarding rules — both ports share the same proxy and backend.
resource "google_compute_global_forwarding_rule" "hub-https" {
  name                  = "${var.env_name}-hub-https"
  target                = google_compute_target_tcp_proxy.hub.id
  port_range            = "443"
  ip_address            = google_compute_global_address.hub.address
  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "hub-http" {
  name                  = "${var.env_name}-hub-http"
  target                = google_compute_target_tcp_proxy.hub.id
  port_range            = "80"
  ip_address            = google_compute_global_address.hub.address
  load_balancing_scheme = "EXTERNAL"
}

resource "google_dns_record_set" "hub-dns" {
  name = "hub.${var.env_name}.${local.zone_suffix}."
  type = "A"
  ttl  = 300

  managed_zone = "${var.env_name}-zone"

  rrdatas = [google_compute_global_address.hub.address]
}

/* Outputs */

output "hub_backend" {
  value = google_compute_backend_service.hub.name
}

output "hub_dns" {
  value = replace(google_dns_record_set.hub-dns.name, "/\\.$/", "")
}

output "hub_ip" {
  value = google_compute_global_address.hub.address
}
