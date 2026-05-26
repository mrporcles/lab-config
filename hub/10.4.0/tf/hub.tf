
/***************************
 * Hub Load Balancer *
 **************************/

resource "google_compute_firewall" "hub-public" {
  name    = "${var.env_name}-hub-public"
  network = "${var.env_name}-pcf-network"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_address" "hub" {
  name = "${var.env_name}-hub"
}

resource "google_compute_target_pool" "hub" {
  name = "${var.env_name}-hub"
}

resource "google_compute_forwarding_rule" "hub-https" {
  name        = "${var.env_name}-hub-https"
  target      = "${google_compute_target_pool.hub.self_link}"
  port_range  = "443"
  ip_protocol = "TCP"
  ip_address  = "${google_compute_address.hub.address}"
}

resource "google_compute_forwarding_rule" "hub-http" {
  name        = "${var.env_name}-hub-http"
  target      = "${google_compute_target_pool.hub.self_link}"
  port_range  = "80"
  ip_protocol = "TCP"
  ip_address  = "${google_compute_address.hub.address}"
}

resource "google_dns_record_set" "hub-dns" {
  name = "hub.${var.env_name}.${local.zone_suffix}."
  type = "A"
  ttl  = 300

  managed_zone = "${var.env_name}-zone"

  rrdatas = [google_compute_address.hub.address]
}

/* Outputs */

output "hub_pool" {
  value = "${google_compute_target_pool.hub.name}"
}

output "hub_dns" {
  value = replace(google_dns_record_set.hub-dns.name, "/\\.$/", "")
}

output "hub_ip" {
  value = "${google_compute_address.hub.address}"
}

