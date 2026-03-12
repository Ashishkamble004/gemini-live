# =============================================================================
# outputs.tf — Key values printed after terraform apply / readable via
#              terraform output
# =============================================================================

output "static_ip_address" {
  description = "Global static IP reserved for the GKE Ingress load balancer"
  value       = google_compute_global_address.ingress_ip.address
}

output "static_ip_name" {
  description = "Resource name of the global static IP (referenced in k8s/ingress.yaml)"
  value       = google_compute_global_address.ingress_ip.name
}

output "gke_cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.main.name
}

output "gke_cluster_location" {
  description = "GKE cluster region"
  value       = google_container_cluster.main.location
}

output "backend_sa_email" {
  description = "Backend GCP service account email (also used as Workload Identity identity)"
  value       = google_service_account.backend.email
}

output "gcs_bucket_name" {
  description = "GCS bucket for call transcripts"
  value       = google_storage_bucket.transcripts.name
}

output "backend_ws_url" {
  description = "Suggested BACKEND_WS_URL value for the ConfigMap (wss://<domain> or wss://<static_ip>)"
  value = var.domain != "" ? "wss://${var.domain}" : "wss://${google_compute_global_address.ingress_ip.address}"
}

output "get_credentials_command" {
  description = "Command to fetch kubectl credentials for this cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region=${google_container_cluster.main.location} --project=${var.project_id} --dns-endpoint"
}

output "dns_instruction" {
  description = "DNS record you need to create if a domain was provided"
  value       = var.domain != "" ? "Create an A record: ${var.domain} → ${google_compute_global_address.ingress_ip.address}" : "No domain specified — use the static IP directly."
}
