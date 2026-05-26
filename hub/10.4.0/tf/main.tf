provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  zone_suffix = "cf-app.com"
}

resource "google_compute_route" "nat-vm-route" {
  name                   = "${var.env_name}-nat-vm-route"
  dest_range             = "0.0.0.0/0"
  network                = "${var.env_name}-pcf-network"
  next_hop_instance      = "${var.env_name}-nat-vm"
  next_hop_instance_zone = "${var.zone}"
  description            = "Route to external network via next-hop VM"
  priority               = 100
  tags                   = ["system", "postgres", "kafka", "clickhouse-metrics", "prometheus", "control", "blobstore", "registry", "compute", "database", "router", "controller", "errands"]
}
