# =============================================================================
# variables.tf — Input variables for Gemini Live MOFSL infra
# =============================================================================

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP region for all regional resources"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Name of the GKE Autopilot cluster"
  type        = string
  default     = "gemini-live-cluster"
}

variable "network" {
  description = "VPC network name for the GKE cluster. Leave as 'default' to use the project default VPC."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "VPC subnetwork name for the GKE cluster. Leave as 'default' to use the default subnet."
  type        = string
  default     = "default"
}

variable "gcs_bucket_name" {
  description = "GCS bucket name for storing call transcripts"
  type        = string
}

variable "rag_corpus_id" {
  description = "Numeric Vertex AI RAG Corpus ID (e.g. 6917529027641081856)"
  type        = string
}

variable "agent_model" {
  description = "Gemini Live model name used by the backend"
  type        = string
  default     = "gemini-live-2.5-flash-native-audio"
}

variable "domain" {
  description = "Custom domain for HTTPS Ingress + managed TLS cert (leave empty to use the static IP only)"
  type        = string
  default     = ""
}

variable "gcp_sa_name" {
  description = "Short name of the GCP service account for the backend workload"
  type        = string
  default     = "gemini-live-backend"
}

variable "ksa_namespace" {
  description = "Kubernetes namespace where the backend is deployed"
  type        = string
  default     = "gemini-live"
}

variable "ksa_name" {
  description = "Kubernetes service account name inside ksa_namespace"
  type        = string
  default     = "gemini-live-sa"
}

variable "static_ip_name" {
  description = "Name for the global static IP address reserved for the GKE Ingress"
  type        = string
  default     = "gemini-live-ip"
}
