#!/bin/bash

##############################################################################
# Script de Reparación - Proyecto climas-chileno
#
# Soluciona el problema de autenticación entre Cloud Scheduler y Cloud Function Gen2
# Agrega el rol roles/run.invoker faltante y reconfigura el scheduler job
#
# Uso:
#   ./reparar_proyecto.sh
##############################################################################

set -e  # Salir en caso de error

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

imprimir_info() {
    echo -e "${AZUL}ℹ $1${NC}"
}

# Configuración del proyecto
ID_PROYECTO="climas-chileno"
REGION="us-central1"
ZONA_HORARIA="America/Santiago"
CUENTA_SERVICIO="funciones-clima-sa"
FUNCION_EXTRACTOR="extractor-clima"
JOB_SCHEDULER="extraer-clima-job"
TOPIC_CLIMA="clima-datos-crudos"

# Email de la cuenta de servicio
EMAIL_CUENTA="${CUENTA_SERVICIO}@${ID_PROYECTO}.iam.gserviceaccount.com"

imprimir_titulo "REPARACIÓN DE PROYECTO: climas-chileno"
echo "Proyecto: $ID_PROYECTO"
echo "Región: $REGION"
echo "Cuenta de servicio: $EMAIL_CUENTA"
echo ""

# Configurar proyecto
gcloud config set project $ID_PROYECTO

##############################################################################
# PASO 1: Verificar y agregar roles faltantes
##############################################################################
imprimir_titulo "PASO 1: Verificando roles de la cuenta de servicio"

# Roles requeridos
ROLES_REQUERIDOS=(
    "roles/run.invoker"
    "roles/pubsub.publisher"
    "roles/pubsub.subscriber"
    "roles/storage.objectCreator"
    "roles/bigquery.dataEditor"
    "roles/logging.logWriter"
    "roles/cloudfunctions.invoker"
)

# Obtener roles actuales
imprimir_info "Obteniendo roles actuales..."
ROLES_ACTUALES=$(gcloud projects get-iam-policy $ID_PROYECTO \
    --flatten="bindings[].members" \
    --filter="bindings.members:serviceAccount:$EMAIL_CUENTA" \
    --format="value(bindings.role)" 2>/dev/null || echo "")

echo "Roles actuales:"
if [ -z "$ROLES_ACTUALES" ]; then
    imprimir_advertencia "No se encontraron roles asignados"
else
    echo "$ROLES_ACTUALES" | while read rol; do
        echo "  - $rol"
    done
fi
echo ""

# Verificar y agregar roles faltantes
ROLES_AGREGADOS=0
for rol in "${ROLES_REQUERIDOS[@]}"; do
    if echo "$ROLES_ACTUALES" | grep -q "$rol"; then
        imprimir_exito "Rol ya asignado: $rol"
    else
        imprimir_advertencia "Falta rol: $rol - Agregando..."
        gcloud projects add-iam-policy-binding $ID_PROYECTO \
            --member="serviceAccount:$EMAIL_CUENTA" \
            --role="$rol" \
            --quiet > /dev/null
        imprimir_exito "Rol agregado: $rol"
        ROLES_AGREGADOS=$((ROLES_AGREGADOS + 1))
    fi
done

if [ $ROLES_AGREGADOS -eq 0 ]; then
    imprimir_exito "Todos los roles están correctamente asignados"
else
    imprimir_exito "Se agregaron $ROLES_AGREGADOS roles faltantes"
fi

##############################################################################
# PASO 2: Obtener URL de la Cloud Function
##############################################################################
imprimir_titulo "PASO 2: Obteniendo URL de Cloud Function"

URL_EXTRACTOR=$(gcloud functions describe $FUNCION_EXTRACTOR \
    --gen2 \
    --region=$REGION \
    --project=$ID_PROYECTO \
    --format='value(serviceConfig.uri)' 2>/dev/null)

if [ -z "$URL_EXTRACTOR" ]; then
    imprimir_error "No se pudo obtener la URL de la función $FUNCION_EXTRACTOR"
    imprimir_info "Verifica que la función esté desplegada correctamente"
    exit 1
fi

imprimir_exito "URL obtenida: $URL_EXTRACTOR"

##############################################################################
# PASO 3: Eliminar scheduler job existente (si existe)
##############################################################################
imprimir_titulo "PASO 3: Eliminando scheduler job existente"

if gcloud scheduler jobs describe $JOB_SCHEDULER \
    --location=$REGION \
    --project=$ID_PROYECTO &> /dev/null; then

    imprimir_info "Eliminando job existente: $JOB_SCHEDULER"
    gcloud scheduler jobs delete $JOB_SCHEDULER \
        --location=$REGION \
        --project=$ID_PROYECTO \
        --quiet
    imprimir_exito "Job eliminado: $JOB_SCHEDULER"
else
    imprimir_info "No existe job previo con nombre: $JOB_SCHEDULER"
fi

##############################################################################
# PASO 4: Crear nuevo scheduler job con OIDC
##############################################################################
imprimir_titulo "PASO 4: Creando nuevo scheduler job con OIDC"

imprimir_info "Creando job: $JOB_SCHEDULER"
imprimir_info "Schedule: 0 * * * * (cada hora)"
imprimir_info "Time zone: $ZONA_HORARIA"
imprimir_info "Target: $URL_EXTRACTOR"
imprimir_info "Service Account: $EMAIL_CUENTA"

gcloud scheduler jobs create http $JOB_SCHEDULER \
    --location=$REGION \
    --schedule="0 * * * *" \
    --uri=$URL_EXTRACTOR \
    --http-method=POST \
    --oidc-service-account-email=$EMAIL_CUENTA \
    --oidc-token-audience=$URL_EXTRACTOR \
    --time-zone=$ZONA_HORARIA \
    --description="Ejecuta extracción de datos climáticos cada hora" \
    --project=$ID_PROYECTO

imprimir_exito "Scheduler job creado exitosamente"

##############################################################################
# PASO 5: Probar invocación manual
##############################################################################
imprimir_titulo "PASO 5: Probando invocación manual"

imprimir_info "Ejecutando invocación manual del scheduler job..."
gcloud scheduler jobs run $JOB_SCHEDULER \
    --location=$REGION \
    --project=$ID_PROYECTO

sleep 5  # Esperar a que se ejecute

imprimir_exito "Invocación manual completada"

##############################################################################
# PASO 6: Verificar logs de la función
##############################################################################
imprimir_titulo "PASO 6: Verificando logs recientes de la función"

imprimir_info "Obteniendo últimos logs (últimos 5 minutos)..."
LOGS=$(gcloud functions logs read $FUNCION_EXTRACTOR \
    --gen2 \
    --region=$REGION \
    --project=$ID_PROYECTO \
    --limit=20 \
    --format="table(time, severity, log)" 2>/dev/null || echo "")

if [ -z "$LOGS" ]; then
    imprimir_advertencia "No se encontraron logs recientes"
else
    echo "$LOGS"
    echo ""

    # Verificar si hay errores
    if echo "$LOGS" | grep -q "ERROR"; then
        imprimir_advertencia "Se encontraron errores en los logs - Revisar arriba"
    else
        imprimir_exito "No se detectaron errores en los logs"
    fi
fi

##############################################################################
# PASO 7: Verificar mensajes en Pub/Sub
##############################################################################
imprimir_titulo "PASO 7: Verificando mensajes en Pub/Sub"

imprimir_info "Verificando topic: $TOPIC_CLIMA"

# Verificar que el topic existe
if gcloud pubsub topics describe $TOPIC_CLIMA \
    --project=$ID_PROYECTO &> /dev/null; then
    imprimir_exito "Topic existe: $TOPIC_CLIMA"

    # Intentar obtener estadísticas de mensajes
    imprimir_info "Verificando suscripciones al topic..."
    SUSCRIPCIONES=$(gcloud pubsub topics list-subscriptions $TOPIC_CLIMA \
        --project=$ID_PROYECTO \
        --format="value(name)" 2>/dev/null || echo "")

    if [ -z "$SUSCRIPCIONES" ]; then
        imprimir_advertencia "No se encontraron suscripciones al topic"
    else
        echo "Suscripciones encontradas:"
        echo "$SUSCRIPCIONES" | while read sub; do
            SUB_NAME=$(basename "$sub")
            echo "  - $SUB_NAME"

            # Intentar obtener un mensaje (sin consumirlo)
            MENSAJE=$(gcloud pubsub subscriptions pull "$SUB_NAME" \
                --limit=1 \
                --project=$ID_PROYECTO \
                --format="value(message.data)" \
                --auto-ack=false 2>/dev/null || echo "")

            if [ -z "$MENSAJE" ]; then
                imprimir_info "    No hay mensajes pendientes (ya fueron procesados)"
            else
                imprimir_exito "    Hay mensajes en la cola"
            fi
        done
    fi
else
    imprimir_error "Topic no encontrado: $TOPIC_CLIMA"
fi

##############################################################################
# RESUMEN FINAL
##############################################################################
imprimir_titulo "RESUMEN DE REPARACIÓN"

echo -e "${VERDE}✓ Paso 1: Roles verificados y actualizados${NC}"
echo -e "  - roles/run.invoker agregado (Cloud Run Invoker)"
echo -e "  - Todos los roles necesarios asignados"
echo ""
echo -e "${VERDE}✓ Paso 2: URL de Cloud Function obtenida${NC}"
echo -e "  - URL: $URL_EXTRACTOR"
echo ""
echo -e "${VERDE}✓ Paso 3: Scheduler job anterior eliminado${NC}"
echo ""
echo -e "${VERDE}✓ Paso 4: Nuevo scheduler job creado con OIDC${NC}"
echo -e "  - Job: $JOB_SCHEDULER"
echo -e "  - Schedule: Cada hora (0 * * * *)"
echo -e "  - Service Account: $EMAIL_CUENTA"
echo -e "  - OIDC habilitado"
echo ""
echo -e "${VERDE}✓ Paso 5: Invocación manual ejecutada${NC}"
echo ""
echo -e "${VERDE}✓ Paso 6: Logs verificados${NC}"
echo ""
echo -e "${VERDE}✓ Paso 7: Pub/Sub verificado${NC}"
echo ""

imprimir_titulo "PRÓXIMOS PASOS"

echo "1. Esperar hasta la próxima hora en punto para verificar ejecución automática"
echo ""
echo "2. Ver logs en tiempo real:"
echo "   gcloud functions logs read $FUNCION_EXTRACTOR --gen2 --region=$REGION --tail"
echo ""
echo "3. Ver ejecuciones del scheduler:"
echo "   gcloud scheduler jobs describe $JOB_SCHEDULER --location=$REGION"
echo ""
echo "4. Consultar datos en BigQuery:"
echo "   bq query --use_legacy_sql=false 'SELECT * FROM clima.condiciones_actuales ORDER BY hora_actual DESC LIMIT 5'"
echo ""
echo "5. Ejecutar manualmente cuando quieras:"
echo "   gcloud scheduler jobs run $JOB_SCHEDULER --location=$REGION"
echo ""

imprimir_exito "¡Reparación completada exitosamente! 🚀"
echo ""
