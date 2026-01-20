#!/bin/bash

##############################################################################
# Script de Despliegue - Sistema de Integración con Google Weather API
# Mejorado: robustez, seguridad, manejo de temporales, permisos para OIDC
#
# Uso:
#   ./desplegar.sh [ID_PROYECTO] [REGION]
#
# Ejemplo:
#   ./desplegar.sh clima-chileno us-central1
##############################################################################

set -euo pipefail
IFS=$'\n\t'

# Colores para output
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
ROJO='\033[0;31m'
AZUL='\033[0;34m'
NC='\033[0m' # Sin color

# Función para imprimir mensajes con formato
imprimir_titulo() {
    echo -e "\n${AZUL}========================================${NC}"
    echo -e "${AZUL}$1${NC}"
    echo -e "${AZUL}========================================${NC}\n"
}

imprimir_exito() {
    echo -e "${VERDE}✓ $1${NC}"
}

imprimir_advertencia() {
    echo -e "${AMARILLO}⚠ $1${NC}"
}

imprimir_error() {
    echo -e "${ROJO}✗ $1${NC}"
}

# Función para verificar si un comando existe
verificar_comando() {
    if ! command -v "$1" &> /dev/null; then
        imprimir_error "El comando '$1' no está instalado"
        exit 1
    fi
}

# Configuración
ID_PROYECTO=${1:-""}
REGION=${2:-"us-central1"}
ZONA_HORARIA="America/Santiago"

# Nombres de recursos
TOPIC_DATOS_CRUDOS="clima-datos-crudos"
TOPIC_DLQ="clima-datos-dlq"
BUCKET_BRONCE="datos-clima-bronce"
DATASET_CLIMA="clima"
TABLA_CONDICIONES="condiciones_actuales"
FUNCION_EXTRACTOR="extractor-clima"
FUNCION_PROCESADOR="procesador-clima"
JOB_SCHEDULER="extraer-clima-job"
CUENTA_SERVICIO="funciones-clima-sa"

# Validar parámetros
if [ -z "${ID_PROYECTO}" ]; then
    imprimir_error "Debe proporcionar el ID del proyecto"
    echo "Uso: $0 [ID_PROYECTO] [REGION]"
    echo "Ejemplo: $0 clima-chileno us-central1"
    exit 1
fi

imprimir_titulo "INICIANDO DESPLIEGUE - SISTEMA DE CLIMA GCP"
echo "Proyecto: ${ID_PROYECTO}"
echo "Región: ${REGION}"
echo "Zona horaria: ${ZONA_HORARIA}"

# Verificar dependencias
imprimir_titulo "Verificando dependencias"
verificar_comando "gcloud"
verificar_comando "gsutil"
verificar_comando "bq"
verificar_comando "python3"
imprimir_exito "Todas las dependencias están instaladas"

# Verificar autenticación y proyecto activo
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "${CURRENT_PROJECT}" ]; then
    imprimir_advertencia "No hay proyecto configurado en gcloud. Se configurará el proyecto proporcionado."
fi

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' &>/dev/null; then
    imprimir_error "No hay una cuenta autenticada en gcloud. Ejecute 'gcloud auth login' antes de continuar."
    exit 1
fi

# Configurar proyecto
imprimir_titulo "Configurando proyecto de GCP"
gcloud config set project "${ID_PROYECTO}" --quiet
imprimir_exito "Proyecto configurado: ${ID_PROYECTO}"

# Habilitar APIs necesarias
imprimir_titulo "Habilitando APIs de Google Cloud"
apis=(
    "cloudfunctions.googleapis.com"
    "cloudbuild.googleapis.com"
    "cloudscheduler.googleapis.com"
    "pubsub.googleapis.com"
    "storage.googleapis.com"
    "bigquery.googleapis.com"
    "logging.googleapis.com"
    "run.googleapis.com"
    "eventarc.googleapis.com"
    "weather.googleapis.com"
)

for api in "${apis[@]}"; do
    echo "Habilitando ${api}..."
    gcloud services enable "${api}" --project="${ID_PROYECTO}" --quiet
done
imprimir_exito "APIs habilitadas correctamente"

# Crear cuenta de servicio
imprimir_titulo "Creando cuenta de servicio"
SA_EMAIL="${CUENTA_SERVICIO}@${ID_PROYECTO}.iam.gserviceaccount.com"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${ID_PROYECTO}" &> /dev/null; then
    imprimir_advertencia "Cuenta de servicio ya existe: ${CUENTA_SERVICIO}"
else
    gcloud iam service-accounts create "${CUENTA_SERVICIO}" \
        --display-name="Cuenta de Servicio para Cloud Functions de Clima" \
        --project="${ID_PROYECTO}" \
        --quiet
    imprimir_exito "Cuenta de servicio creada: ${CUENTA_SERVICIO}"
fi

# Asignar roles a la cuenta de servicio
imprimir_titulo "Asignando permisos a cuenta de servicio"
roles=(
    "roles/pubsub.publisher"
    "roles/pubsub.subscriber"
    "roles/storage.objectCreator"
    "roles/bigquery.dataEditor"
    "roles/logging.logWriter"
    "roles/cloudfunctions.invoker"
)

for rol in "${roles[@]}"; do
    echo "Asignando rol: ${rol}"
    gcloud projects add-iam-policy-binding "${ID_PROYECTO}" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="${rol}" \
        --quiet
done
imprimir_exito "Permisos asignados correctamente"

# Crear topics de Pub/Sub
imprimir_titulo "Creando topics de Pub/Sub"

# Topic principal
if gcloud pubsub topics describe "${TOPIC_DATOS_CRUDOS}" --project="${ID_PROYECTO}" &> /dev/null; then
    imprimir_advertencia "Topic ya existe: ${TOPIC_DATOS_CRUDOS}"
else
    gcloud pubsub topics create "${TOPIC_DATOS_CRUDOS}" --project="${ID_PROYECTO}" --quiet
    imprimir_exito "Topic creado: ${TOPIC_DATOS_CRUDOS}"
fi

# Topic DLQ
if gcloud pubsub topics describe "${TOPIC_DLQ}" --project="${ID_PROYECTO}" &> /dev/null; then
    imprimir_advertencia "Topic DLQ ya existe: ${TOPIC_DLQ}"
else
    gcloud pubsub topics create "${TOPIC_DLQ}" --project="${ID_PROYECTO}" --quiet
    imprimir_exito "Topic DLQ creado: ${TOPIC_DLQ}"
fi

# Crear bucket de Cloud Storage
imprimir_titulo "Creando bucket de Cloud Storage"
BUCKET_COMPLETO="${ID_PROYECTO}-${BUCKET_BRONCE}"

if gsutil ls -p "${ID_PROYECTO}" "gs://${BUCKET_COMPLETO}" &> /dev/null; then
    imprimir_advertencia "Bucket ya existe: ${BUCKET_COMPLETO}"
else
    gsutil mb -p "${ID_PROYECTO}" -l "${REGION}" "gs://${BUCKET_COMPLETO}"

    # Configurar versionado
    gsutil versioning set on "gs://${BUCKET_COMPLETO}"

    # Configurar ciclo de vida en archivo temporal seguro
    LIFECYCLE_FILE=$(mktemp)
    cat > "${LIFECYCLE_FILE}" <<EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {"type": "SetStorageClass", "storageClass": "NEARLINE"},
        "condition": {"age": 30}
      },
      {
        "action": {"type": "SetStorageClass", "storageClass": "COLDLINE"},
        "condition": {"age": 90}
      },
      {
        "action": {"type": "Delete"},
        "condition": {"age": 365}
      }
    ]
  }
}
EOF
    gsutil lifecycle set "${LIFECYCLE_FILE}" "gs://${BUCKET_COMPLETO}"
    rm -f "${LIFECYCLE_FILE}"

    imprimir_exito "Bucket creado: ${BUCKET_COMPLETO}"
fi

# Crear dataset de BigQuery
imprimir_titulo "Creando dataset de BigQuery"
if bq show --project_id="${ID_PROYECTO}" "${DATASET_CLIMA}" &>/dev/null; then
    imprimir_advertencia "Dataset ya existe: ${DATASET_CLIMA}"
else
    bq mk --project_id="${ID_PROYECTO}" \
        --location="${REGION}" \
        --description="Dataset para datos climáticos procesados" \
        "${DATASET_CLIMA}"
    imprimir_exito "Dataset creado: ${DATASET_CLIMA}"
fi

# Crear tabla de BigQuery
imprimir_titulo "Creando tabla de BigQuery"
SCHEMA_FILE=$(mktemp)
cat > "${SCHEMA_FILE}" <<EOF
[
  {"name": "nombre_ubicacion", "type": "STRING", "mode": "REQUIRED"},
  {"name": "latitud", "type": "FLOAT64", "mode": "REQUIRED"},
  {"name": "longitud", "type": "FLOAT64", "mode": "REQUIRED"},
  {"name": "hora_actual", "type": "TIMESTAMP", "mode": "REQUIRED"},
  {"name": "zona_horaria", "type": "STRING", "mode": "NULLABLE"},
  {"name": "temperatura", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "sensacion_termica", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "punto_rocio", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "indice_calor", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "sensacion_viento", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "condicion_clima", "type": "STRING", "mode": "NULLABLE"},
  {"name": "descripcion_clima", "type": "STRING", "mode": "NULLABLE"},
  {"name": "probabilidad_precipitacion", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "precipitacion_acumulada", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "presion_aire", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "velocidad_viento", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "direccion_viento", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "visibilidad", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "humedad_relativa", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "indice_uv", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "probabilidad_tormenta", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "cobertura_nubes", "type": "FLOAT64", "mode": "NULLABLE"},
  {"name": "es_dia", "type": "BOOLEAN", "mode": "NULLABLE"},
  {"name": "marca_tiempo_ingestion", "type": "TIMESTAMP", "mode": "REQUIRED"},
  {"name": "uri_datos_crudos", "type": "STRING", "mode": "NULLABLE"},
  {"name": "datos_json_crudo", "type": "STRING", "mode": "NULLABLE"}
]
EOF

if bq ls --project_id="${ID_PROYECTO}" "${DATASET_CLIMA}" | grep -q "${TABLA_CONDICIONES}"; then
    imprimir_advertencia "Tabla ya existe: ${TABLA_CONDICIONES}"
else
    bq mk --project_id="${ID_PROYECTO}" \
        --table \
        --time_partitioning_field=hora_actual \
        --time_partitioning_type=DAY \
        --clustering_fields=nombre_ubicacion \
        --description="Condiciones climáticas actuales de ubicaciones monitoreadas" \
        "${DATASET_CLIMA}.${TABLA_CONDICIONES}" \
        "${SCHEMA_FILE}"
    imprimir_exito "Tabla creada: ${TABLA_CONDICIONES}"
fi
rm -f "${SCHEMA_FILE}"

# Desplegar Cloud Function Extractor
imprimir_titulo "Desplegando Cloud Function: Extractor"
gcloud functions deploy "${FUNCION_EXTRACTOR}" \
    --gen2 \
    --runtime=python311 \
    --region="${REGION}" \
    --source=./extractor \
    --entry-point=extraer_clima \
    --trigger-http \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="GCP_PROJECT=${ID_PROYECTO}" \
    --memory=256MB \
    --timeout=60s \
    --max-instances=10 \
    --project="${ID_PROYECTO}" \
    --quiet

imprimir_exito "Cloud Function desplegada: ${FUNCION_EXTRACTOR}"

# Obtener URL del extractor
URL_EXTRACTOR=$(gcloud functions describe "${FUNCION_EXTRACTOR}" \
    --gen2 \
    --region="${REGION}" \
    --project="${ID_PROYECTO}" \
    --format='value(serviceConfig.uri)')

echo "URL del extractor: ${URL_EXTRACTOR}"

# Desplegar Cloud Function Procesador
imprimir_titulo "Desplegando Cloud Function: Procesador"
gcloud functions deploy "${FUNCION_PROCESADOR}" \
    --gen2 \
    --runtime=python311 \
    --region="${REGION}" \
    --source=./procesador \
    --entry-point=procesar_clima \
    --trigger-topic="${TOPIC_DATOS_CRUDOS}" \
    --service-account="${SA_EMAIL}" \
    --set-env-vars="GCP_PROJECT=${ID_PROYECTO},BUCKET_CLIMA=${BUCKET_COMPLETO},DATASET_CLIMA=${DATASET_CLIMA},TABLA_CLIMA=${TABLA_CONDICIONES}" \
    --memory=512MB \
    --timeout=120s \
    --max-instances=10 \
    --project="${ID_PROYECTO}" \
    --quiet

imprimir_exito "Cloud Function desplegada: ${FUNCION_PROCESADOR}"

# Preparar binding para Cloud Scheduler OIDC: permitir que el servicio de Cloud Scheduler
# pueda crear tokens en nombre de la cuenta de servicio que invocará la función.
imprimir_titulo "Configurando permisos para Cloud Scheduler OIDC"
PROJECT_NUMBER=$(gcloud projects describe "${ID_PROYECTO}" --format='value(projectNumber)')
if [ -z "${PROJECT_NUMBER}" ]; then
    imprimir_error "No se pudo obtener el projectNumber del proyecto ${ID_PROYECTO}"
    exit 1
fi

# Service account que usa Cloud Scheduler para emitir tokens:
SCHEDULER_SA="service-${PROJECT_NUMBER}@gcp-sa-cloudscheduler.iam.gserviceaccount.com"

# Conceder roles/iam.serviceAccountTokenCreator sobre la cuenta de servicio SA_EMAIL al servicio de Cloud Scheduler
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
    --member="serviceAccount:${SCHEDULER_SA}" \
    --role="roles/iam.serviceAccountTokenCreator" \
    --project="${ID_PROYECTO}" \
    --quiet || {
        imprimir_advertencia "No se pudo asignar roles/iam.serviceAccountTokenCreator automáticamente. Verifica permisos y asígnalo manualmente si es necesario."
    }
imprimir_exito "Permiso de token OIDC configurado para Cloud Scheduler (si no hubo errores)"

# Crear job de Cloud Scheduler
imprimir_titulo "Creando job de Cloud Scheduler"

# Eliminar job existente si existe
if gcloud scheduler jobs describe "${JOB_SCHEDULER}" --location="${REGION}" --project="${ID_PROYECTO}" &> /dev/null; then
    imprimir_advertencia "Eliminando job existente: ${JOB_SCHEDULER}"
    gcloud scheduler jobs delete "${JOB_SCHEDULER}" \
        --location="${REGION}" \
        --project="${ID_PROYECTO}" \
        --quiet
fi

# Crear nuevo job
gcloud scheduler jobs create http "${JOB_SCHEDULER}" \
    --location="${REGION}" \
    --schedule="0 * * * *" \
    --uri="${URL_EXTRACTOR}" \
    --http-method=POST \
    --oidc-service-account-email="${SA_EMAIL}" \
    --oidc-token-audience="${URL_EXTRACTOR}" \
    --time-zone="${ZONA_HORARIA}" \
    --description="Ejecuta extracción de datos climáticos cada hora" \
    --project="${ID_PROYECTO}" \
    --quiet

imprimir_exito "Job de Cloud Scheduler creado: ${JOB_SCHEDULER}"

# Resumen final
imprimir_titulo "DESPLIEGUE COMPLETADO EXITOSAMENTE"

echo -e "${VERDE}Recursos creados:${NC}"
echo "  • Topic Pub/Sub: ${TOPIC_DATOS_CRUDOS}"
echo "  • Topic DLQ: ${TOPIC_DLQ}"
echo "  • Bucket GCS: gs://${BUCKET_COMPLETO}"
echo "  • Dataset BigQuery: ${DATASET_CLIMA}"
echo "  • Tabla BigQuery: ${TABLA_CONDICIONES}"
echo "  • Cloud Function Extractor: ${FUNCION_EXTRACTOR}"
echo "  • Cloud Function Procesador: ${FUNCION_PROCESADOR}"
echo "  • Cloud Scheduler Job: ${JOB_SCHEDULER}"
echo ""
echo -e "${AZUL}URLs importantes:${NC}"
echo "  • Extractor: ${URL_EXTRACTOR}"
echo "  • Logs: https://console.cloud.google.com/logs/query?project=${ID_PROYECTO}"
echo "  • BigQuery: https://console.cloud.google.com/bigquery?project=${ID_PROYECTO}&d=${DATASET_CLIMA}&t=${TABLA_CONDICIONES}"
echo ""
echo -e "${AMARILLO}Próximos pasos:${NC}"
echo "  1. Probar extractor manualmente: curl -X POST ${URL_EXTRACTOR}"
echo "  2. Ver logs: gcloud functions logs read ${FUNCION_EXTRACTOR} --gen2 --region=${REGION}"
echo "  3. Consultar BigQuery: bq query --use_legacy_sql=false 'SELECT * FROM ${DATASET_CLIMA}.${TABLA_CONDICIONES} LIMIT 10'"
echo "  4. El scheduler ejecutará automáticamente cada hora"
echo ""
imprimir_exito "¡Listo! El sistema está desplegado y funcionando."
