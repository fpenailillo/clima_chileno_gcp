#!/bin/bash

# Script para recrear la tabla de BigQuery con el schema correcto

set -e

# Colores
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

ID_PROYECTO="${1:-climas-chileno}"
DATASET="clima"
TABLA="condiciones_actuales"

echo -e "${AZUL}"
echo "========================================"
echo "RECREAR TABLA DE BIGQUERY"
echo "========================================"
echo -e "${NC}"

echo "Proyecto: $ID_PROYECTO"
echo "Dataset: $DATASET"
echo "Tabla: $TABLA"
echo ""

# Verificar cuántos registros hay
echo -e "${AMARILLO}Verificando cantidad de registros...${NC}"
REGISTROS=$(bq query --use_legacy_sql=false --project_id=$ID_PROYECTO --format=csv \
    "SELECT COUNT(*) FROM $DATASET.$TABLA" 2>/dev/null | tail -1 || echo "0")

echo "Registros en la tabla: $REGISTROS"
echo ""

if [ "$REGISTROS" -gt 0 ]; then
    echo -e "${ROJO}⚠️  ADVERTENCIA: La tabla tiene $REGISTROS registros${NC}"
    read -p "¿Estás seguro de eliminar la tabla? (escribe 'si' para confirmar): " confirmacion
    if [ "$confirmacion" != "si" ]; then
        echo "Operación cancelada"
        exit 1
    fi
fi

# Eliminar tabla existente
echo -e "${AMARILLO}Eliminando tabla existente...${NC}"
bq rm -f -t "$ID_PROYECTO:$DATASET.$TABLA" 2>/dev/null || echo "Tabla no existe o ya fue eliminada"
echo -e "${VERDE}✓ Tabla eliminada${NC}"
echo ""

# Crear schema
echo -e "${AMARILLO}Creando schema...${NC}"
cat > /tmp/schema_clima.json <<'EOF'
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

echo -e "${VERDE}✓ Schema creado${NC}"
echo ""

# Crear tabla nueva
echo -e "${AMARILLO}Creando tabla nueva...${NC}"
bq mk --project_id=$ID_PROYECTO \
    --table \
    --time_partitioning_field=hora_actual \
    --time_partitioning_type=DAY \
    --clustering_fields=nombre_ubicacion \
    --description="Condiciones climáticas actuales de ubicaciones monitoreadas" \
    $DATASET.$TABLA \
    /tmp/schema_clima.json

echo -e "${VERDE}✓ Tabla creada exitosamente${NC}"
echo ""

# Mostrar schema de la tabla nueva
echo -e "${AMARILLO}Schema de la tabla nueva:${NC}"
bq show --schema --format=prettyjson "$ID_PROYECTO:$DATASET.$TABLA"

echo ""
echo -e "${AZUL}"
echo "========================================"
echo "TABLA RECREADA EXITOSAMENTE"
echo "========================================"
echo -e "${NC}"
echo ""
echo "Ahora puedes probar el sistema:"
echo "  gcloud scheduler jobs run extraer-clima-job --location=us-central1"
echo "  # Esperar 1 minuto"
echo "  ./verificar_flujo_completo.sh $ID_PROYECTO"
