#!/bin/bash

##############################################################################
# Script de Verificación Rápida - Sistema de Clima
#
# Verifica que todos los componentes estén funcionando correctamente
#
# Uso:
#   ./verificar.sh
##############################################################################

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="climas-chileno"
REGION="us-central1"

echo -e "${AZUL}========================================${NC}"
echo -e "${AZUL}VERIFICACIÓN RÁPIDA - Sistema de Clima${NC}"
echo -e "${AZUL}========================================${NC}\n"

gcloud config set project $ID_PROYECTO --quiet

# 1. Verificar Cloud Functions
echo -e "${AZUL}1. Cloud Functions:${NC}"
EXTRACTOR=$(gcloud functions describe extractor-clima --gen2 --region=$REGION --format='value(state)' 2>/dev/null)
PROCESADOR=$(gcloud functions describe procesador-clima --gen2 --region=$REGION --format='value(state)' 2>/dev/null)

if [ "$EXTRACTOR" = "ACTIVE" ]; then
    echo -e "  ${VERDE}✓${NC} extractor-clima: ACTIVE"
else
    echo -e "  ${ROJO}✗${NC} extractor-clima: $EXTRACTOR"
fi

if [ "$PROCESADOR" = "ACTIVE" ]; then
    echo -e "  ${VERDE}✓${NC} procesador-clima: ACTIVE"
else
    echo -e "  ${ROJO}✗${NC} procesador-clima: $PROCESADOR"
fi

# 2. Verificar Cloud Scheduler
echo -e "\n${AZUL}2. Cloud Scheduler:${NC}"
SCHEDULER=$(gcloud scheduler jobs describe extraer-clima-job --location=$REGION --format='value(state)' 2>/dev/null)

if [ "$SCHEDULER" = "ENABLED" ]; then
    echo -e "  ${VERDE}✓${NC} extraer-clima-job: ENABLED"
    NEXT=$(gcloud scheduler jobs describe extraer-clima-job --location=$REGION --format='value(scheduleTime)' 2>/dev/null)
    echo -e "    Próxima ejecución: $NEXT"
else
    echo -e "  ${ROJO}✗${NC} extraer-clima-job: $SCHEDULER"
fi

# 3. Verificar Pub/Sub
echo -e "\n${AZUL}3. Pub/Sub Topic:${NC}"
TOPIC=$(gcloud pubsub topics describe clima-datos-crudos --format='value(name)' 2>/dev/null)

if [ -n "$TOPIC" ]; then
    echo -e "  ${VERDE}✓${NC} clima-datos-crudos: Existe"
else
    echo -e "  ${ROJO}✗${NC} clima-datos-crudos: No encontrado"
fi

# 4. Verificar BigQuery
echo -e "\n${AZUL}4. BigQuery:${NC}"
DATASET=$(bq ls --project_id=$ID_PROYECTO -d 2>/dev/null | grep clima | awk '{print $1}')

if [ "$DATASET" = "clima" ]; then
    echo -e "  ${VERDE}✓${NC} Dataset 'clima': Existe"

    TABLA=$(bq ls --project_id=$ID_PROYECTO clima 2>/dev/null | grep condiciones_actuales | awk '{print $1}')
    if [ "$TABLA" = "condiciones_actuales" ]; then
        echo -e "  ${VERDE}✓${NC} Tabla 'condiciones_actuales': Existe"

        # Contar registros
        REGISTROS=$(bq query --use_legacy_sql=false --format=csv --project_id=$ID_PROYECTO \
            'SELECT COUNT(*) as total FROM clima.condiciones_actuales' 2>/dev/null | tail -1)
        echo -e "    Registros: $REGISTROS"
    else
        echo -e "  ${ROJO}✗${NC} Tabla 'condiciones_actuales': No encontrada"
    fi
else
    echo -e "  ${ROJO}✗${NC} Dataset 'clima': No encontrado"
fi

# 5. Verificar Cloud Storage
echo -e "\n${AZUL}5. Cloud Storage:${NC}"
BUCKET="climas-chileno-datos-clima-bronce"
BUCKET_EXISTS=$(gsutil ls -p $ID_PROYECTO gs://$BUCKET 2>/dev/null)

if [ -n "$BUCKET_EXISTS" ]; then
    echo -e "  ${VERDE}✓${NC} Bucket gs://$BUCKET: Existe"
else
    echo -e "  ${ROJO}✗${NC} Bucket gs://$BUCKET: No encontrado"
fi

# 6. Probar invocación
echo -e "\n${AZUL}6. Probar invocación del scheduler:${NC}"
echo -e "  Ejecutando scheduler manualmente..."
gcloud scheduler jobs run extraer-clima-job --location=$REGION --quiet

echo -e "  Esperando 10 segundos..."
sleep 10

# Ver logs recientes
echo -e "\n${AZUL}7. Últimos logs del extractor:${NC}"
gcloud functions logs read extractor-clima --gen2 --region=$REGION --limit=5 2>/dev/null | head -20

echo -e "\n${AZUL}========================================${NC}"
echo -e "${VERDE}Verificación completada${NC}"
echo -e "${AZUL}========================================${NC}"
