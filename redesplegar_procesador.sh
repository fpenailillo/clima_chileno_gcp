#!/bin/bash

# Script para redesplegar solo el procesador
# Útil cuando solo se actualiza el código del procesador

set -e

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="${1:-climas-chileno}"
REGION="${2:-us-central1}"

FUNCION_PROCESADOR="procesador-clima"
CUENTA_SERVICIO="funciones-clima-sa"
TOPIC_DATOS_CRUDOS="clima-datos-crudos"
BUCKET_BRONCE="datos-clima-bronce"
BUCKET_COMPLETO="${ID_PROYECTO}-${BUCKET_BRONCE}"
DATASET_CLIMA="clima"
TABLA_CONDICIONES="condiciones_actuales"

echo -e "${AZUL}"
echo "========================================"
echo "REDESPLEGAR PROCESADOR"
echo "========================================"
echo -e "${NC}"

echo "Proyecto: $ID_PROYECTO"
echo "Región: $REGION"
echo "Función: $FUNCION_PROCESADOR"
echo ""

# Configurar proyecto
echo -e "${AMARILLO}Configurando proyecto...${NC}"
gcloud config set project $ID_PROYECTO
echo -e "${VERDE}✓ Proyecto configurado${NC}"
echo ""

# Redesplegar Cloud Function Procesador
echo -e "${AMARILLO}Redesplegando Cloud Function: $FUNCION_PROCESADOR${NC}"
echo ""

gcloud functions deploy $FUNCION_PROCESADOR \
    --gen2 \
    --region=$REGION \
    --runtime=python311 \
    --source=./procesador \
    --entry-point=procesar_clima \
    --trigger-topic=$TOPIC_DATOS_CRUDOS \
    --service-account=${CUENTA_SERVICIO}@${ID_PROYECTO}.iam.gserviceaccount.com \
    --set-env-vars=GCP_PROJECT=$ID_PROYECTO,BUCKET_CLIMA=$BUCKET_COMPLETO,DATASET_CLIMA=$DATASET_CLIMA,TABLA_CLIMA=$TABLA_CONDICIONES \
    --memory=512MB \
    --timeout=120s \
    --max-instances=10 \
    --project=$ID_PROYECTO

echo ""
echo -e "${VERDE}✓ Cloud Function redesplegada: $FUNCION_PROCESADOR${NC}"

echo ""
echo -e "${AZUL}"
echo "========================================"
echo "PROCESADOR REDESPLEGADO EXITOSAMENTE"
echo "========================================"
echo -e "${NC}"
echo ""
echo "Ahora puedes probar el flujo completo:"
echo "  gcloud scheduler jobs run extraer-clima-job --location=$REGION"
echo "  sleep 60"
echo "  ./verificar_flujo_completo.sh $ID_PROYECTO"
echo ""
echo "O ejecutar manualmente con autenticación:"
echo "  ./probar_extractor_manual.sh $ID_PROYECTO"
echo ""
