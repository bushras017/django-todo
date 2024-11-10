# terraform/monitoring.tf

# BigQuery dataset for logs
resource "google_bigquery_dataset" "security_logs" {
  dataset_id                  = "security_logs"
  friendly_name              = "Security Logs"
  description                = "Dataset for security logs and alerts"
  location                   = var.region
  default_table_expiration_ms = 7776000000  # 90 days

  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }

  # Add explicit access for the service account
  access {
    role          = "WRITER"
    user_by_email = var.service_account_email  # Add this variable
  }
    lifecycle {
    prevent_destroy = true
  }
}

# BigQuery table for alerts
resource "google_bigquery_table" "alerts" {
  dataset_id = google_bigquery_dataset.security_logs.dataset_id
  table_id   = "alerts"

  time_partitioning {
    type = "DAY"
  }

  schema = <<EOF
[
  {
    "name": "alert_name",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "severity",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "instance",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "description",
    "type": "STRING",
    "mode": "NULLABLE"
  },
  {
    "name": "timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED"
  }
]
EOF
}

# PubSub topic for alerts
resource "google_pubsub_topic" "prometheus_alerts" {
  name = "prometheus-alerts"
    lifecycle {
    prevent_destroy = true
  }
}

# Cloud Function
resource "google_storage_bucket" "function_bucket" {
  name     = "${var.project_id}-functions"
  location = var.region
  uniform_bucket_level_access = true
    lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_object" "function_archive" {
  name   = "function-${timestamp()}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/function.zip"
}

# Added IAM binding for function service account
resource "google_project_iam_binding" "function_invoker" {
  project = var.project_id
  role    = "roles/cloudfunctions.invoker"
  members = ["serviceAccount:${var.service_account_email}"]
}

resource "google_cloudfunctions_function" "alert_handler" {
  name        = "alert-handler"
  description = "Handles Prometheus alerts"
  runtime     = "python39"

  available_memory_mb   = 256
  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.function_archive.name
  
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.prometheus_alerts.name
  }

  environment_variables = {
    PROJECT_ID = var.project_id
  }

  # Add service account
  service_account_email = var.service_account_email
}

# Log sink with explicit permission
resource "google_logging_project_sink" "security_sink" {
  name        = "security-logs-sink"
  description = "Security logs export to BigQuery"
  
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.security_logs.dataset_id}"
  
  filter = <<-EOT
    resource.type="gce_instance" AND
    (
      jsonPayload.event_type="security_event" OR
      jsonPayload.type="high_cpu" OR
      jsonPayload.type="disk_space_low" OR
      jsonPayload.type="failed_logins" OR
      severity>=WARNING
    )
  EOT

  unique_writer_identity = true

  # Added BigQuery writer IAM binding
  bigquery_options {
    use_partitioned_tables = true
  }
}

# Add IAM binding for the log sink service account
resource "google_project_iam_binding" "log_sink_writer" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  members = [google_logging_project_sink.security_sink.writer_identity]
}