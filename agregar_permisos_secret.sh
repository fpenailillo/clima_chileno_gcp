#!/bin/bash

# Script para agregar permisos IAM al secret de Weather API Key
# La cuenta de servicio necesita acceso explícito al secret

set -e

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="${1:-climas-chileno}"
NOMBRE_SECRET="weather-api-key"
CUENTA_SERVICIO="funciones-clima-sa@${ID_PROYECTO}.iam.gserviceaccount.com"

echo -e "${AZUL}"
echo "========================================"
echo "CONFIGURAR PERMISOS DE SECRET MANAGER"
echo "========================================"
echo -e "${NC}"

echo "Proyecto: $ID_PROYECTO"
echo "Secret: $NOMBRE_SECRET"
echo "Cuenta de servicio: $CUENTA_SERVICIO"
echo ""

# Verificar que el secret existe
echo -e "${AMARILLO}Verificando secret...${NC}"
if ! gcloud secrets describe $NOMBRE_SECRET --project=$ID_PROYECTO &> /dev/null; then
    echo -e "${ROJO}✗ Secret '$NOMBRE_SECRET' no existe${NC}"
    exit 1
fi
echo -e "${VERDE}✓ Secret existe${NC}"

# Agregar permisos IAM al secret
echo ""
echo -e "${AMARILLO}Agregando permiso secretAccessor a la cuenta de servicio...${NC}"

gcloud secrets add-iam-policy-binding $NOMBRE_SECRET \
    --member="serviceAccount:${CUENTA_SERVICIO}" \
    --role="roles/secretmanager.secretAccessor" \
    --project=$ID_PROYECTO

echo ""
echo -e "${VERDE}✓ Permisos agregados correctamente${NC}"

# Mostrar permisos actuales
echo ""
echo -e "${AMARILLO}Permisos actuales del secret:${NC}"
gcloud secrets get-iam-policy $NOMBRE_SECRET --project=$ID_PROYECTO

echo ""
echo -e "${AZUL}========================================"
echo "PERMISOS CONFIGURADOS EXITOSAMENTE"
echo "========================================${NC}"
echo ""
echo "Ahora la Cloud Function puede acceder al secret para obtener la API Key"
