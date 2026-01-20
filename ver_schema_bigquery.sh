#!/bin/bash

# Script para ver el schema actual de la tabla de BigQuery

ID_PROYECTO="${1:-climas-chileno}"
DATASET="clima"
TABLA="condiciones_actuales"

echo "Schema actual de $DATASET.$TABLA:"
echo ""

bq show --schema --format=prettyjson "$ID_PROYECTO:$DATASET.$TABLA"
