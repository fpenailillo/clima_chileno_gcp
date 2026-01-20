#!/bin/bash

# Script de verificación del extractor
# Revisa logs y estado del sistema

set -e

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="climas-chileno"
REGION="us-central1"
FUNCION="extractor-clima"

echo -e "${AZUL}"
echo "========================================"
echo "VERIFICACIÓN DEL EXTRACTOR"
echo "========================================"
echo -e "${NC}"

# 1. Ver logs del extractor
echo -e "${AMARILLO}📋 Logs del extractor (últimas 20 líneas):${NC}"
echo ""
gcloud functions logs read $FUNCION \
    --gen2 \
    --region=$REGION \
    --limit=20 \
    --project=$ID_PROYECTO

echo ""
echo -e "${AMARILLO}📊 Estado del job de Cloud Scheduler:${NC}"
echo ""
gcloud scheduler jobs describe extraer-clima-job \
    --location=$REGION \
    --project=$ID_PROYECTO

echo ""
echo -e "${AMARILLO}🔐 Verificando permisos en Secret Manager:${NC}"
echo ""

# Verificar si el secret existe
if gcloud secrets describe weather-api-key --project=$ID_PROYECTO &> /dev/null; then
    echo -e "${VERDE}✓ Secret 'weather-api-key' existe${NC}"

    # Ver permisos del secret
    echo ""
    echo "Permisos del secret:"
    gcloud secrets get-iam-policy weather-api-key --project=$ID_PROYECTO

    # Ver número de versiones
    VERSION_COUNT=$(gcloud secrets versions list weather-api-key \
        --project=$ID_PROYECTO \
        --format="value(name)" 2>/dev/null | wc -l)

    echo ""
    echo -e "${VERDE}✓ Secret tiene $VERSION_COUNT versión(es)${NC}"
else
    echo -e "${ROJO}✗ Secret 'weather-api-key' NO existe${NC}"
fi

echo ""
echo -e "${AMARILLO}🧪 Probando invocación autenticada:${NC}"
echo ""

# Obtener token de identidad
TOKEN=$(gcloud auth print-identity-token)
URL=$(gcloud functions describe $FUNCION \
    --gen2 \
    --region=$REGION \
    --project=$ID_PROYECTO \
    --format="value(serviceConfig.uri)")

echo "Invocando: $URL"
echo ""

# Hacer llamada autenticada
curl -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -w "\n\nHTTP Status: %{http_code}\n" \
    -s

echo ""
echo -e "${AZUL}========================================"
echo "VERIFICACIÓN COMPLETADA"
echo "========================================${NC}"
