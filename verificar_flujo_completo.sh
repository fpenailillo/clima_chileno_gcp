#!/bin/bash

# Script de verificación completa del flujo end-to-end
# Extractor → Pub/Sub → Procesador → BigQuery/GCS

set -e

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="${1:-climas-chileno}"
REGION="us-central1"

echo -e "${AZUL}"
echo "========================================"
echo "VERIFICACIÓN FLUJO COMPLETO END-TO-END"
echo "========================================"
echo -e "${NC}"

echo "Proyecto: $ID_PROYECTO"
echo "Región: $REGION"
echo ""

##############################################################################
# 1. VERIFICAR LOGS DEL EXTRACTOR (últimas 5 entradas)
##############################################################################
echo -e "${AMARILLO}📋 1. Logs del Extractor (últimas 5 entradas):${NC}"
echo ""

gcloud functions logs read extractor-clima \
    --gen2 \
    --region=$REGION \
    --limit=5 \
    --project=$ID_PROYECTO \
    --format="table(level, time_utc, log)" 2>/dev/null || echo "No hay logs recientes"

echo ""

##############################################################################
# 2. VERIFICAR LOGS DEL PROCESADOR
##############################################################################
echo -e "${AMARILLO}📋 2. Logs del Procesador (últimas 10 entradas):${NC}"
echo ""

gcloud functions logs read procesador-clima \
    --gen2 \
    --region=$REGION \
    --limit=10 \
    --project=$ID_PROYECTO \
    --format="table(level, time_utc, log)" 2>/dev/null || echo "No hay logs recientes"

echo ""

##############################################################################
# 3. VERIFICAR ARCHIVOS EN CLOUD STORAGE (Bronze)
##############################################################################
echo -e "${AMARILLO}📦 3. Archivos en Cloud Storage (últimos 10):${NC}"
echo ""

BUCKET="gs://climas-chileno-datos-clima-bronce"

# Listar últimos archivos
gsutil ls -l "$BUCKET/clima-raw-*.json" 2>/dev/null | tail -20 || echo "No hay archivos en el bucket"

echo ""

# Contar archivos totales
TOTAL_ARCHIVOS=$(gsutil ls "$BUCKET/clima-raw-*.json" 2>/dev/null | wc -l)
echo -e "${VERDE}Total archivos en bucket: $TOTAL_ARCHIVOS${NC}"

echo ""

##############################################################################
# 4. VERIFICAR DATOS EN BIGQUERY
##############################################################################
echo -e "${AMARILLO}📊 4. Datos en BigQuery:${NC}"
echo ""

# Contar registros totales
echo "Conteo total de registros:"
bq query --use_legacy_sql=false --project_id=$ID_PROYECTO \
    "SELECT COUNT(*) as total_registros FROM clima.condiciones_actuales" 2>/dev/null || echo "No se pudo consultar BigQuery"

echo ""

# Últimos 5 registros
echo "Últimos 5 registros (más recientes):"
bq query --use_legacy_sql=false --project_id=$ID_PROYECTO --format=pretty \
    "SELECT
        nombre_ubicacion,
        CAST(temperatura AS STRING) as temp_c,
        descripcion_clima,
        FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', hora_actual) as fecha_hora,
        FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', marca_tiempo_ingestion) as ingestion
    FROM clima.condiciones_actuales
    ORDER BY marca_tiempo_ingestion DESC
    LIMIT 5" 2>/dev/null || echo "No se pudo consultar BigQuery"

echo ""

# Registros por ubicación
echo "Registros por ubicación:"
bq query --use_legacy_sql=false --project_id=$ID_PROYECTO --format=pretty \
    "SELECT
        nombre_ubicacion,
        COUNT(*) as cantidad,
        MAX(marca_tiempo_ingestion) as ultima_ingestion
    FROM clima.condiciones_actuales
    GROUP BY nombre_ubicacion
    ORDER BY nombre_ubicacion" 2>/dev/null || echo "No se pudo consultar BigQuery"

echo ""

##############################################################################
# 5. VERIFICAR MENSAJES EN PUB/SUB
##############################################################################
echo -e "${AMARILLO}📮 5. Estado de Pub/Sub:${NC}"
echo ""

echo "Topic principal:"
gcloud pubsub topics describe clima-datos-crudos --project=$ID_PROYECTO 2>/dev/null || echo "Topic no encontrado"

echo ""

# Ver subscripciones
echo "Subscripciones activas:"
gcloud pubsub subscriptions list --project=$ID_PROYECTO --format="table(name, topic, ackDeadlineSeconds)" | grep clima || echo "No hay subscripciones"

echo ""

##############################################################################
# 6. ÚLTIMO SCHEDULER JOB EXECUTION
##############################################################################
echo -e "${AMARILLO}⏰ 6. Estado del Scheduler Job:${NC}"
echo ""

gcloud scheduler jobs describe extraer-clima-job \
    --location=$REGION \
    --project=$ID_PROYECTO \
    --format="table(state, lastAttemptTime, scheduleTime)" 2>/dev/null || echo "Job no encontrado"

echo ""

##############################################################################
# RESUMEN
##############################################################################
echo -e "${AZUL}"
echo "========================================"
echo "RESUMEN"
echo "========================================"
echo -e "${NC}"

# Verificar si hay datos recientes (últimos 10 minutos)
REGISTROS_RECIENTES=$(bq query --use_legacy_sql=false --project_id=$ID_PROYECTO --format=csv \
    "SELECT COUNT(*) FROM clima.condiciones_actuales
    WHERE marca_tiempo_ingestion >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 10 MINUTE)" 2>/dev/null | tail -1)

if [ "$REGISTROS_RECIENTES" -gt 0 ]; then
    echo -e "${VERDE}✓ Sistema funcionando correctamente${NC}"
    echo -e "${VERDE}✓ Se encontraron $REGISTROS_RECIENTES registros en los últimos 10 minutos${NC}"
else
    echo -e "${AMARILLO}⚠ No se encontraron registros recientes (últimos 10 minutos)${NC}"
    echo -e "${AMARILLO}  Esto es normal si el scheduler no ha ejecutado recientemente${NC}"
fi

echo ""
echo "Para ejecutar manualmente:"
echo "  gcloud scheduler jobs run extraer-clima-job --location=$REGION --project=$ID_PROYECTO"
echo ""
echo "Para ver logs en tiempo real:"
echo "  gcloud functions logs read extractor-clima --gen2 --region=$REGION --limit=20"
echo "  gcloud functions logs read procesador-clima --gen2 --region=$REGION --limit=20"
echo ""
