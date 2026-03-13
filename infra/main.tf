# =============================================================================
# main.tf — GCP infrastructure for Gemini Live MOFSL Contact Center (GKE)
# =============================================================================
#
# Manages:
#   • Required GCP API enablement
#   • GCP service account + IAM bindings (Vertex AI, GCS, Workload Identity)
#   • Cloud Build SA permissions (GCR push + GKE rolling update)
#   • GCS bucket for call transcripts
#   • Global static IP for GKE Gateway load balancer
#   • Certificate Manager certificate, cert map & entry (when domain is set)
#   • GKE Autopilot cluster (optional custom VPC / subnetwork)
#   • Workload Identity KSA → GSA binding
#
# Kubernetes manifests (k8s/ directory) are NOT managed here — apply them
# separately with kubectl after running terraform apply.
#
# Usage:
#   cd infra/
#   cp terraform.tfvars.example terraform.tfvars   # fill in your values
#   terraform init
#   terraform plan
#   terraform apply
#
# To tear down ALL infrastructure:
#   terraform destroy
#
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "google_project" "current" {
  project_id = var.project_id
}

# ---------------------------------------------------------------------------
# Enable required GCP APIs
# ---------------------------------------------------------------------------

locals {
  required_apis = [
    "container.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "containerregistry.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "certificatemanager.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false  # leave APIs enabled when destroying infra
}

# ---------------------------------------------------------------------------
# GCP Service Account (backend workload identity)
# ---------------------------------------------------------------------------

resource "google_service_account" "backend" {
  account_id   = var.gcp_sa_name
  display_name = "Gemini Live Backend"
  project      = var.project_id

  depends_on = [google_project_service.apis]
}

# --- Vertex AI access (Gemini Live + RAG) ---
resource "google_project_iam_member" "backend_aiplatform" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# --- GCS read/write for transcript storage ---
resource "google_project_iam_member" "backend_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.backend.email}"
}

# ---------------------------------------------------------------------------
# Cloud Build SA permissions (CI/CD pipeline)
# ---------------------------------------------------------------------------

locals {
  cloudbuild_sa = "${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
  cloudbuild_roles = [
    "roles/container.developer",   # kubectl rolling update
    "roles/storage.admin",         # push to GCR / Artifact Registry
    "roles/iam.serviceAccountUser",
  ]
}

resource "google_project_iam_member" "cloudbuild" {
  for_each = toset(local.cloudbuild_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.cloudbuild_sa}"

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# GCS bucket — call transcripts
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "transcripts" {
  name          = var.gcs_bucket_name
  project       = var.project_id
  location      = var.region
  force_destroy = false  # protect existing transcripts from accidental destroy

  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = 30
    }
  }

  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
    condition {
      age = 90
    }
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Global static IP — GKE Gateway load balancer
# ---------------------------------------------------------------------------

# Note: resource is named "ingress_ip" for backwards compatibility with
# existing Terraform state. Renaming would destroy and recreate the IP,
# releasing the static address and breaking DNS.
resource "google_compute_global_address" "ingress_ip" {
  name    = var.static_ip_name
  project = var.project_id

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Certificate Manager — TLS for GKE Gateway (replaces ManagedCertificate)
#
# Only created when var.domain is set. Uses load-balancer-based domain
# validation — the cert will provision once the DNS A record points to
# the global static IP and the Gateway is created.
# ---------------------------------------------------------------------------

resource "google_certificate_manager_certificate" "default" {
  count   = var.domain != "" ? 1 : 0
  name    = "gemini-live-cert"
  project = var.project_id

  managed {
    domains = [var.domain]
  }

  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map" "default" {
  count   = var.domain != "" ? 1 : 0
  name    = "gemini-live-cert-map"
  project = var.project_id

  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map_entry" "default" {
  count        = var.domain != "" ? 1 : 0
  name         = "gemini-live-cert-entry"
  project      = var.project_id
  map          = google_certificate_manager_certificate_map.default[0].name
  certificates = [google_certificate_manager_certificate.default[0].id]
  hostname     = var.domain

  depends_on = [
    google_certificate_manager_certificate_map.default,
    google_certificate_manager_certificate.default,
  ]
}

# ---------------------------------------------------------------------------
# GKE Autopilot cluster
# ---------------------------------------------------------------------------

resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  # Autopilot manages nodes automatically — no need for node pool config
  enable_autopilot = true

  # VPC / subnetwork — uses 'default' unless overridden by the user
  network    = var.network
  subnetwork = var.subnetwork

  # Workload Identity (required for keyless GCP access from pods)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Enable DNS endpoint with external traffic so kubectl works from outside
  # the VPC (e.g. Cloud Shell, local machine) without a VPN or bastion.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
  }

  # Allow terraform destroy to delete the cluster
  deletion_protection = false

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Workload Identity binding — KSA → GSA
#
# This lets pods in namespace/ksa_name authenticate as the GSA
# (google_service_account.backend) without mounting a key file.
# ---------------------------------------------------------------------------

resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.backend.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.ksa_namespace}/${var.ksa_name}]"
}
