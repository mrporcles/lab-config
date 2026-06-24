provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  zone_suffix = "cf-app.com"
}
