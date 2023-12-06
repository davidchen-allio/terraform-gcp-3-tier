terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.51.0"
    }
  }
}

locals {
  project                        = "qwiklabs-gcp-02-f7c2235fbdf6"
  forwarding_rule_name           = "cepf-infra-lb"
  service_port                   = 80
  region                         = "us-central1"
  zone                           = "${local.region}-b"
  load_balancer_session_affinity = "CLIENT_IP"
  load_balancer_backend_name     = "cepf-infra-lb-backend-default"
  disable_health_check           = false
  ip_protocol                    = "TCP"
  service_account_email          = "21509468164-compute@developer.gserviceaccount.com"
}

provider "google" {
  project = local.project
  region  = local.region
  zone    = local.zone
}

// State bucket :
terraform {
  backend "gcs" {
    bucket = "${local.project}-bucket-tfstate"
  }
}

// Database :
resource "google_sql_database_instance" "instance" {
  name             = "cepf-instance"
  database_version = "POSTGRES_14"
  region           = local.region

  settings {
    # Second-generation instance tiers are based on the machine
    # type. See argument reference below.
    tier = "db-f1-micro"
  }
  deletion_protection = "false"
}
resource "google_sql_user" "users" {
  name     = "root"
  instance = google_sql_database_instance.instance.name
  password = "postgres"
}
resource "google_sql_database" "database" {
  name     = "cepf-db"
  instance = google_sql_database_instance.instance.name
}
resource "google_compute_autoscaler" "foobar" {
  name    = "my-autoscaler"
  project = local.project
  zone    = local.zone
  target  = google_compute_instance_group_manager.foobar.self_link

  autoscaling_policy {
    max_replicas    = 4
    min_replicas    = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.6
    }
  }
}

resource "google_compute_instance_template" "foobar" {
  name           = "cepf-infra-lb-group1-mig"
  machine_type   = "n1-standard-1"
  can_ip_forward = false
  project        = local.project
  tags           = ["gaoxuan", "bar", "allow-lb-service"]

  disk {
    source_image = data.google_compute_image.my_image.self_link
  }

  network_interface {
    network = "default"
  }

  metadata = {
    # startup-script = "
    # gsutil cp -r gs://cloud-training/cepf/cepf020/flask_cloudsql_example_v1.zip .
    # apt-get install zip unzip wget python3-venv -y
    # unzip flask_cloudsql_example_v1.zip
    # cd flask_cloudsql_example/sqlalchemy
    # wget https://dl.google.com/cloudsql/cloud_sql_proxy.linux.amd64 -O cloud_sql_proxy
    # chmod +x cloud_sql_proxy
    # export INSTANCE_HOST='127.0.0.1'
    # export DB_PORT='5432'
    # export DB_USER='postgres'
    # export DB_PASS='postgres'
    # export DB_NAME='cepf-db'
    # CONNECTION_NAME=$(gcloud sql instances describe cepf-instance --format="value(connectionName)")
    # nohup ./cloud_sql_proxy -instances=${CONNECTION_NAME}=tcp:5432 &
    # python3 -m venv env
    # source env/bin/activate
    # pip install -r requirements.txt
    # sed -i 's/127.0.0.1/0.0.0.0/g' app.py
    # sed -i 's/8080/80/g' app.py
    # nohup python app.py &
    # "
  }

  service_account {
    email  = "21509468164-compute@developer.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_target_pool" "foobar" {
  name    = "my-target-pool"
  project = local.project
  region  = local.region
}

resource "google_compute_instance_group_manager" "foobar" {
  name    = "cepf-infra-lb-group1-mig"
  project = local.project
  version {
    instance_template = google_compute_instance_template.foobar.self_link
    name              = "primary"
  }

  target_pools       = [google_compute_target_pool.foobar.self_link]
  base_instance_name = "terraform"
}

data "google_compute_image" "my_image" {
  family  = "debian-11"
  project = "debian-cloud"
}

# module "lb" {
# source = "GoogleCloudPlatform/lb/google"
# version = "2.2.0"
# region = local.region
# name = "cepf-infra-lb"
# service_port = 80
# target_tags = ["my-target-pool"]
# network = "default"
# ip_protocol = "http"
# }

// module lb
locals {
  health_check_port = null
}

resource "google_compute_forwarding_rule" "default" {
  provider              = google-beta
  project               = local.project
  name                  = local.forwarding_rule_name
  target                = google_compute_target_pool.default.self_link
  load_balancing_scheme = "EXTERNAL"
  port_range            = local.service_port
  region                = local.region
  ip_address            = null
  ip_protocol           = local.ip_protocol
  labels                = null
}

resource "google_compute_target_pool" "default" {
  project          = local.project
  name             = local.load_balancer_backend_name
  region           = local.region
  session_affinity = local.load_balancer_session_affinity

  health_checks = local.disable_health_check ? [] : [google_compute_http_health_check.default[0].self_link]
}

resource "google_compute_http_health_check" "default" {
  count   = local.disable_health_check ? 0 : 1
  project = local.project
  name    = "${local.load_balancer_backend_name}-hc"

  check_interval_sec  = null
  healthy_threshold   = null
  timeout_sec         = null
  unhealthy_threshold = null

  port         = local.health_check_port == null ? local.service_port : local.health_check_port
  request_path = null
  host         = null
}

resource "google_compute_firewall" "default-lb-fw" {
  project = local.project
  name    = "${local.load_balancer_backend_name}-vm-service"
  network = "default"

  allow {
    protocol = lower(local.ip_protocol)
    ports    = [local.service_port]
  }

  source_ranges = ["0.0.0.0/0"]

  target_tags = null

  target_service_accounts = ["21509468164-compute@developer.gserviceaccount.com"]
}

resource "google_compute_firewall" "default-hc-fw" {
  count   = local.disable_health_check ? 0 : 1
  project = local.project
  name    = "${local.load_balancer_backend_name}-hc"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = [80]
  }

  source_ranges = ["35.191.0.0/16", "209.85.152.0/22", "209.85.204.0/22", "0.0.0.0/24"]

  target_tags = null

  target_service_accounts = ["21509468164-compute@developer.gserviceaccount.com"]
}

resource "google_compute_router" "router" {
  project = local.project
  name    = "nat-router"
  network = "default"
  region  = local.region
}

## Create Nat Gateway

resource "google_compute_router_nat" "nat" {
  name                               = "my-router-nat"
  router                             = google_compute_router.router.name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
