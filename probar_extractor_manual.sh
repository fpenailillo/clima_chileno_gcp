#!/bin/bash

# Script para probar el extractor manualmente con autenticación correcta

set -e

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="${1:-climas-chileno}"
REGION="us-central1"
FUNCION="extractor-clima"

echo -e "${AZUL}"
echo "========================================"
echo "PROBAR EXTRACTOR MANUALMENTE"
echo "========================================"
echo -e "${NC}"

# Obtener URL del extractor
echo -e "${AMARILLO}Obteniendo URL del extractor...${NC}"
URL=$(gcloud functions describe $FUNCION \
    --gen2 \
    --region=$REGION \
    --project=$ID_PROYECTO \
    --format="value(serviceConfig.uri)")

echo "URL: $URL"
echo ""

# Obtener token de identidad
echo -e "${AMARILLO}Obteniendo token de autenticación...${NC}"
TOKEN=$(gcloud auth print-identity-token)
echo -e "${VERDE}✓ Token obtenido${NC}"
echo ""

# Invocar función
echo -e "${AMARILLO}Invocando extractor...${NC}"
echo ""

RESPONSE=$(curl -X POST "$URL" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -w "\n\n---\nHTTP Status: %{http_code}\nTiempo total: %{time_total}s\n" \
    -s)

echo "$RESPONSE"
echo ""

# Parsear respuesta para verificar éxito
if echo "$RESPONSE" | grep -q '"estado":"exitoso"'; then
    echo -e "${VERDE}"
    echo "========================================"
    echo "✓ EXTRACTOR FUNCIONANDO CORRECTAMENTE"
    echo "========================================"
    echo -e "${NC}"

    # Extraer detalles
    MENSAJES_PUBLICADOS=$(echo "$RESPONSE" | grep -o '"mensajes_publicados":[0-9]*' | cut -d':' -f2)
    MENSAJES_FALLIDOS=$(echo "$RESPONSE" | grep -o '"mensajes_fallidos":[0-9]*' | cut -d':' -f2)

    echo "Mensajes publicados: $MENSAJES_PUBLICADOS"
    echo "Mensajes fallidos: $MENSAJES_FALLIDOS"
    echo ""
    echo "Ahora espera 30-60 segundos y verifica BigQuery:"
    echo "  ./verificar_flujo_completo.sh $ID_PROYECTO"
else
    echo -e "${ROJO}"
    echo "========================================"
    echo "✗ ERROR EN EL EXTRACTOR"
    echo "========================================"
    echo -e "${NC}"
    echo "Revisa los logs:"
    echo "  gcloud functions logs read $FUNCION --gen2 --region=$REGION --limit=10"
fi

echo ""
