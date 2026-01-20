/**
 * Infraestructura de Google Cloud Platform para Sistema de Clima
 *
 * Este archivo de Terraform define la infraestructura completa para:
 * - Extracción de datos climáticos desde Google Weather API
 * - Procesamiento event-driven con Pub/Sub
 * - Almacenamiento en Cloud Storage (capa bronce) y BigQuery (capa plata)
 * - Orquestación con Cloud Scheduler
 *
 * Arquitectura:
 * Cloud Scheduler → Cloud Function (Extractor) → Pub/Sub → Cloud Function (Procesador) → GCS + BigQuery
 */

terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

# Variables de configuración
variable "id_proyecto" {
  description = "ID del proyecto de Google Cloud"
  type        = string
}

variable "region" {
  description = "Región de GCP para desplegar recursos"
  type        = string
  default     = "us-central1"
}

variable "zona_horaria" {
  description = "Zona horaria para Cloud Scheduler"
  type        = string
  default     = "America/Santiago"
}

variable "frecuencia_extraccion" {
  description = "Frecuencia de extracción en formato cron (cada hora por defecto)"
  type        = string
  default     = "0 * * * *"
}

# Provider de Google Cloud
provider "google" {
  project = var.id_proyecto
  region  = var.region
}

# Habilitar APIs necesarias
resource "google_project_service" "apis_requeridas" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudscheduler.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
    "bigquery.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.key
  disable_on_destroy = false
}

# ============================================================================
# PUB/SUB - Mensajería asíncrona
# ============================================================================

# Topic principal para datos crudos del clima
resource "google_pubsub_topic" "clima_datos_crudos" {
  name = "clima-datos-crudos"

  labels = {
    componente = "mensajeria"
    proposito  = "datos-clima-crudos"
  }

  message_retention_duration = "86400s" # 24 horas

  depends_on = [google_project_service.apis_requeridas]
}

# Topic para dead letter queue (mensajes fallidos)
resource "google_pubsub_topic" "clima_datos_dlq" {
  name = "clima-datos-dlq"

  labels = {
    componente = "mensajeria"
    proposito  = "dead-letter-queue"
  }

  message_retention_duration = "604800s" # 7 días

  depends_on = [google_project_service.apis_requeridas]
}

# Suscripción para Cloud Function procesador con dead letter queue
resource "google_pubsub_subscription" "procesador_clima_sub" {
  name  = "procesador-clima-sub"
  topic = google_pubsub_topic.clima_datos_crudos.name

  # Configuración de reintentos
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  # Dead letter queue para mensajes que fallan repetidamente
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.clima_datos_dlq.id
    max_delivery_attempts = 5
  }

  # Configuración de ACK
  ack_deadline_seconds = 60

  # Expiración de mensajes
  message_retention_duration = "86400s" # 24 horas

  labels = {
    componente = "procesamiento"
  }

  depends_on = [google_project_service.apis_requeridas]
}

# ============================================================================
# CLOUD STORAGE - Capa bronce (datos crudos)
# ============================================================================

# Bucket para almacenamiento de datos crudos
resource "google_storage_bucket" "datos_clima_bronce" {
  name          = "${var.id_proyecto}-datos-clima-bronce"
  location      = var.region
  force_destroy = false

  # Versionado para recuperación
  versioning {
    enabled = true
  }

  # Ciclo de vida para optimizar costos
  lifecycle_rule {
    # Mover a Nearline después de 30 días
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = 30
    }
  }

  lifecycle_rule {
    # Mover a Coldline después de 90 días
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
    condition {
      age = 90
    }
  }

  lifecycle_rule {
    # Eliminar después de 365 días
    action {
      type = "Delete"
    }
    condition {
      age = 365
    }
  }

  # Acceso uniforme
  uniform_bucket_level_access = true

  labels = {
    capa       = "bronce"
    tipo_datos = "clima-crudo"
  }

  depends_on = [google_project_service.apis_requeridas]
}

# ============================================================================
# BIGQUERY - Capa plata (datos estructurados)
# ============================================================================

# Dataset para datos climáticos
resource "google_bigquery_dataset" "clima" {
  dataset_id  = "clima"
  location    = var.region
  description = "Dataset para datos climáticos procesados (capa plata)"

  # Tiempo de expiración predeterminado para tablas (opcional)
  default_table_expiration_ms = null

  labels = {
    capa       = "plata"
    tipo_datos = "clima-procesado"
  }

  depends_on = [google_project_service.apis_requeridas]
}

# Tabla para condiciones climáticas actuales
resource "google_bigquery_table" "condiciones_actuales" {
  dataset_id = google_bigquery_dataset.clima.dataset_id
  table_id   = "condiciones_actuales"

  description = "Tabla con condiciones climáticas actuales de ubicaciones monitoreadas"

  # Particionamiento por fecha
  time_partitioning {
    type  = "DAY"
    field = "hora_actual"
  }

  # Clustering para optimizar queries
  clustering = ["nombre_ubicacion"]

  # Esquema de la tabla
  schema = jsonencode([
    {
      name        = "nombre_ubicacion"
      type        = "STRING"
      mode        = "REQUIRED"
      description = "Nombre de la ubicación monitoreada"
    },
    {
      name        = "latitud"
      type        = "FLOAT64"
      mode        = "REQUIRED"
      description = "Latitud de la ubicación"
    },
    {
      name        = "longitud"
      type        = "FLOAT64"
      mode        = "REQUIRED"
      description = "Longitud de la ubicación"
    },
    {
      name        = "hora_actual"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Fecha y hora de la medición"
    },
    {
      name        = "zona_horaria"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Zona horaria de la ubicación"
    },
    {
      name        = "temperatura"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Temperatura actual en grados Celsius"
    },
    {
      name        = "sensacion_termica"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Sensación térmica en grados Celsius"
    },
    {
      name        = "punto_rocio"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Punto de rocío en grados Celsius"
    },
    {
      name        = "indice_calor"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Índice de calor en grados Celsius"
    },
    {
      name        = "sensacion_viento"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Sensación térmica por viento en grados Celsius"
    },
    {
      name        = "condicion_clima"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Código de condición climática"
    },
    {
      name        = "descripcion_clima"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "Descripción textual del clima"
    },
    {
      name        = "probabilidad_precipitacion"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Probabilidad de precipitación (0-100)"
    },
    {
      name        = "precipitacion_acumulada"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Precipitación acumulada en mm"
    },
    {
      name        = "presion_aire"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Presión atmosférica al nivel del mar en hPa"
    },
    {
      name        = "velocidad_viento"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Velocidad del viento en km/h"
    },
    {
      name        = "direccion_viento"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Dirección del viento en grados"
    },
    {
      name        = "visibilidad"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Visibilidad en metros"
    },
    {
      name        = "humedad_relativa"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Humedad relativa en porcentaje"
    },
    {
      name        = "indice_uv"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Índice UV"
    },
    {
      name        = "probabilidad_tormenta"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Probabilidad de tormenta (0-100)"
    },
    {
      name        = "cobertura_nubes"
      type        = "FLOAT64"
      mode        = "NULLABLE"
      description = "Porcentaje de cobertura de nubes"
    },
    {
      name        = "es_dia"
      type        = "BOOLEAN"
      mode        = "NULLABLE"
      description = "Indica si es de día"
    },
    {
      name        = "marca_tiempo_ingestion"
      type        = "TIMESTAMP"
      mode        = "REQUIRED"
      description = "Timestamp de ingesta en BigQuery"
    },
    {
      name        = "uri_datos_crudos"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "URI del archivo crudo en Cloud Storage"
    },
    {
      name        = "datos_json_crudo"
      type        = "STRING"
      mode        = "NULLABLE"
      description = "JSON completo de datos crudos para referencia"
    }
  ])

  labels = {
    tipo = "condiciones-actuales"
  }

  depends_on = [google_bigquery_dataset.clima]
}

# ============================================================================
# CLOUD FUNCTIONS - Procesamiento serverless
# ============================================================================

# Cuenta de servicio para Cloud Functions
resource "google_service_account" "cuenta_funciones_clima" {
  account_id   = "funciones-clima-sa"
  display_name = "Cuenta de Servicio para Cloud Functions de Clima"
  description  = "Cuenta con permisos para ejecutar funciones de extracción y procesamiento de clima"
}

# Permisos para la cuenta de servicio
resource "google_project_iam_member" "permisos_funciones" {
  for_each = toset([
    "roles/pubsub.publisher",       # Publicar mensajes
    "roles/pubsub.subscriber",      # Recibir mensajes
    "roles/storage.objectCreator",  # Crear objetos en GCS
    "roles/bigquery.dataEditor",    # Insertar en BigQuery
    "roles/logging.logWriter",      # Escribir logs
  ])

  project = var.id_proyecto
  role    = each.key
  member  = "serviceAccount:${google_service_account.cuenta_funciones_clima.email}"
}

# Bucket para código fuente de Cloud Functions
resource "google_storage_bucket" "codigo_funciones" {
  name          = "${var.id_proyecto}-codigo-funciones-clima"
  location      = var.region
  force_destroy = true

  uniform_bucket_level_access = true

  depends_on = [google_project_service.apis_requeridas]
}

# Comprimir código del extractor
data "archive_file" "extractor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../extractor"
  output_path = "${path.module}/extractor.zip"
}

# Subir código del extractor a GCS
resource "google_storage_bucket_object" "extractor_codigo" {
  name   = "extractor-${data.archive_file.extractor_zip.output_md5}.zip"
  bucket = google_storage_bucket.codigo_funciones.name
  source = data.archive_file.extractor_zip.output_path
}

# Cloud Function: Extractor de clima
resource "google_cloudfunctions2_function" "extractor_clima" {
  name        = "extractor-clima"
  location    = var.region
  description = "Extrae datos climáticos de Google Weather API y publica a Pub/Sub"

  build_config {
    runtime     = "python311"
    entry_point = "extraer_clima"

    source {
      storage_source {
        bucket = google_storage_bucket.codigo_funciones.name
        object = google_storage_bucket_object.extractor_codigo.name
      }
    }
  }

  service_config {
    max_instance_count = 10
    min_instance_count = 0
    available_memory   = "256M"
    timeout_seconds    = 60

    environment_variables = {
      GCP_PROJECT = var.id_proyecto
    }

    service_account_email = google_service_account.cuenta_funciones_clima.email
  }

  labels = {
    componente = "extractor"
    tipo       = "http"
  }

  depends_on = [google_project_service.apis_requeridas]
}

# Permitir invocación sin autenticación desde Cloud Scheduler
resource "google_cloudfunctions2_function_iam_member" "extractor_invoker" {
  project        = google_cloudfunctions2_function.extractor_clima.project
  location       = google_cloudfunctions2_function.extractor_clima.location
  cloud_function = google_cloudfunctions2_function.extractor_clima.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:${google_service_account.cuenta_funciones_clima.email}"
}

# Comprimir código del procesador
data "archive_file" "procesador_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../procesador"
  output_path = "${path.module}/procesador.zip"
}

# Subir código del procesador a GCS
resource "google_storage_bucket_object" "procesador_codigo" {
  name   = "procesador-${data.archive_file.procesador_zip.output_md5}.zip"
  bucket = google_storage_bucket.codigo_funciones.name
  source = data.archive_file.procesador_zip.output_path
}

# Cloud Function: Procesador de clima
resource "google_cloudfunctions2_function" "procesador_clima" {
  name        = "procesador-clima"
  location    = var.region
  description = "Procesa datos climáticos desde Pub/Sub y almacena en GCS y BigQuery"

  build_config {
    runtime     = "python311"
    entry_point = "procesar_clima"

    source {
      storage_source {
        bucket = google_storage_bucket.codigo_funciones.name
        object = google_storage_bucket_object.procesador_codigo.name
      }
    }
  }

  service_config {
    max_instance_count = 10
    min_instance_count = 0
    available_memory   = "512M"
    timeout_seconds    = 120

    environment_variables = {
      GCP_PROJECT   = var.id_proyecto
      BUCKET_CLIMA  = google_storage_bucket.datos_clima_bronce.name
      DATASET_CLIMA = google_bigquery_dataset.clima.dataset_id
      TABLA_CLIMA   = google_bigquery_table.condiciones_actuales.table_id
    }

    service_account_email = google_service_account.cuenta_funciones_clima.email
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.clima_datos_crudos.id
    retry_policy   = "RETRY_POLICY_RETRY"
  }

  labels = {
    componente = "procesador"
    tipo       = "pubsub"
  }

  depends_on = [google_project_service.apis_requeridas]
}

# ============================================================================
# CLOUD SCHEDULER - Orquestación
# ============================================================================

# Job de Cloud Scheduler para ejecutar extractor periódicamente
resource "google_cloud_scheduler_job" "extraer_clima_job" {
  name             = "extraer-clima-job"
  description      = "Ejecuta la función de extracción de clima cada hora"
  schedule         = var.frecuencia_extraccion
  time_zone        = var.zona_horaria
  attempt_deadline = "320s"

  retry_config {
    retry_count          = 3
    max_retry_duration   = "0s"
    min_backoff_duration = "5s"
    max_backoff_duration = "3600s"
    max_doublings        = 5
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions2_function.extractor_clima.service_config[0].uri

    oidc_token {
      service_account_email = google_service_account.cuenta_funciones_clima.email
    }
  }

  depends_on = [google_project_service.apis_requeridas]
}

# ============================================================================
# OUTPUTS - Información útil después del despliegue
# ============================================================================

output "url_extractor_clima" {
  description = "URL de la Cloud Function extractora"
  value       = google_cloudfunctions2_function.extractor_clima.service_config[0].uri
}

output "nombre_topic_pubsub" {
  description = "Nombre del topic de Pub/Sub para datos crudos"
  value       = google_pubsub_topic.clima_datos_crudos.name
}

output "nombre_bucket_bronce" {
  description = "Nombre del bucket para datos crudos (capa bronce)"
  value       = google_storage_bucket.datos_clima_bronce.name
}

output "id_dataset_bigquery" {
  description = "ID del dataset de BigQuery"
  value       = google_bigquery_dataset.clima.dataset_id
}

output "id_tabla_condiciones" {
  description = "ID de la tabla de condiciones actuales"
  value       = google_bigquery_table.condiciones_actuales.table_id
}

output "tabla_completa_bigquery" {
  description = "Referencia completa de la tabla en BigQuery"
  value       = "${var.id_proyecto}.${google_bigquery_dataset.clima.dataset_id}.${google_bigquery_table.condiciones_actuales.table_id}"
}

output "horario_extraccion" {
  description = "Horario de extracción (formato cron)"
  value       = var.frecuencia_extraccion
}
