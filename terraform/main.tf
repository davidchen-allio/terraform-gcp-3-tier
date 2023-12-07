locals {
  project                        = "qwiklabs-gcp-02-ef7a96eb569c"
  network_name                   = "default"
  subnetwork_name                = "default"
  forwarding_rule_name           = "cepf-infra-lb"
  mig_name                       = "cepf-infra-lb-group1-mig"
  service_port                   = "80"
  region                         = "us-central1"
  zone                           = "${local.region}-b"
  load_balancer_session_affinity = "GENERATED_COOKIE"
  load_balancer_backend_name     = "cepf-infra-lb-backend-default"
  disable_health_check           = false
  protocol                       = "HTTP"
  service_account_email          = "<service_account_email>"
  min_replicas                   = 2
  max_replicas                   = 4
  cpu_utilization_target         = 0.6
  deploy_version                 = "primary"
  machine_type                   = "n1-standard-1"
  startup_script_file_path       = "./script.sh"
  db_instance_name = "cepf-instance"
  db_version = "POSTGRES_14"
  db_instance_tier = "db-f1-micro"
  db_username = "root"
  db_password = "postgres"
  db_database = "cepf-db"
}

data "google_compute_image" "startup_image" {
  family  = "debian-11"
  project = "debian-cloud"
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }

  backend "gcs" {
    bucket = "${local.project}-bucket-tfstate"
  }
}


provider "google" {
  project = local.project
  region  = local.region
  zone    = local.zone
}


data "google_compute_network" "network" {
  name = local.network_name
}

data "google_compute_subnetwork" "subnet" {
  name = local.subnetwork_name
}

resource "google_compute_global_address" "this" {
  name = "${local.project}-ipv4"
}

resource "google_compute_url_map" "default" {
  project         = local.project
  name            = "${local.project}-url-map"
  default_service = google_compute_backend_service.this.self_link
}

resource "google_compute_target_http_proxy" "http" {
  name    = "${local.project}-http"
  url_map = google_compute_url_map.http.self_link
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = local.forwarding_rule_name
  target     = google_compute_target_http_proxy.http.self_link
  ip_address = google_compute_global_address.this.address
  port_range = local.service_port
}

output "Loadbalancer-IPv4-Address" {
  value = google_compute_global_address.this.address
}

resource "google_compute_backend_service" "this" {
  name        = local.load_balancer_backend_name
  port_name   = "http"
  protocol    = local.protocol
  timeout_sec = 10

  session_affinity = local.load_balancer_session_affinity

  health_checks = [google_compute_http_health_check.this.id]

  backend {
    group                 = google_compute_instance_group_manager.this.instance_group
    balancing_mode        = "RATE"
    capacity_scaler       = 1.0
    max_rate_per_instance = 500
  }
}

resource "google_compute_http_health_check" "this" {
  name               = "${local.project}-healthcheck"
  request_path       = "/"
  check_interval_sec = 1
  timeout_sec        = 1
}

resource "google_compute_instance_group_manager" "this" {
  name    = local.mig_name
  project = local.project

  base_instance_name = local.project
  zone               = local.zone

  version {
    name = local.deploy_version
    instance_template = google_compute_instance_template.this.id
  }

  target_size = local.min_replicas

  named_port {
    name = "web"
    port = tonumber(local.service_port)
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.autohealing.id
    initial_delay_sec = 60
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_percent     = 100
    max_unavailable_fixed = 0
    replacement_method    = "SUBSTITUTE"
  }
}

resource "google_compute_health_check" "autohealing" {
  name                = "${local.project}-autohealing"
  check_interval_sec  = 30
  timeout_sec         = 30
  healthy_threshold   = 10
  unhealthy_threshold = 30

  http_health_check {
    request_path = "/"
    port         = local.service_port
  }
}

resource "google_compute_instance_template" "this" {
  name = local.mig_name

  tags = ["gaoxuan"]

  labels = {
    service = local.project
    version = local.deploy_version
  }

  metadata = {
    version = local.deploy_version
  }

  machine_type            = local.machine_type
  can_ip_forward          = false
  metadata_startup_script = file(local.startup_script_file_path)

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  disk {
    source_image = data.google_compute_image.startup_image.self_link
    boot         = true
    disk_type    = "pd-balanced"
  }

  network_interface {
    network    = data.google_compute_network.network.name
    subnetwork = data.google_compute_subnetwork.subnet.name
  }

  service_account {
    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    email  = local.service_account_email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}


resource "google_compute_autoscaler" "this" {
  name    = "${local.project}-autoscaler"
  project = local.project
  zone    = local.zone
  target  = google_compute_instance_group_manager.this.self_link

  autoscaling_policy {
    max_replicas    = local.max_replicas
    min_replicas    = local.min_replicas
    cooldown_period = 60

    cpu_utilization {
      target = local.cpu_utilization_target
    }
  }
}

resource "google_compute_firewall" "this" {
  name    = "${local.project}-allow-healthcheck"
  network = data.google_compute_network.network.name

  allow {
    protocol = "tcp"
    ports    = [local.service_port]
  }
  
  priority = 1000
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags = ["gaoxuan"]
}

resource "google_sql_database_instance" "instance" {
  name             = local.db_instance_name
  database_version = local.db_version
  region           = local.region

  settings {
    # Second-generation instance tiers are based on the machine
    # type. See argument reference below.
    tier = local.db_instance_tier
  }
  deletion_protection = "false"
}
resource "google_sql_user" "users" {
  name     = local.db_username
  instance = google_sql_database_instance.instance.name
  password = local.db_password
}
resource "google_sql_database" "database" {
  name     = local.db_database
  instance = google_sql_database_instance.instance.name
}

resource "google_compute_router" "router" {
  project = local.project
  name    = "${local.project}-nat-router"
  network = data.google_compute_network.network.name
  region  = local.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${local.project}-router-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}