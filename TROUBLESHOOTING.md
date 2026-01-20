# Guía de Solución de Problemas

## Entendiendo los Logs

### ✅ Funcionamiento Normal

Cuando el sistema funciona correctamente, verás:

```json
{
  "estado": "exitoso",
  "mensajes_publicados": 3,
  "mensajes_fallidos": 0,
  "total_ubicaciones": 3
}
```

### ⚠️ Errores Comunes y Cómo Interpretarlos

#### 1. "The request was not authenticated"

**Qué significa**: La función fue invocada sin autenticación

**Cuándo es normal**:
- Cuando ejecutas `curl -X POST https://extractor-clima-XXX.run.app` sin token
- Estos errores son **esperados** y no indican un problema

**Cuándo es un problema**:
- Cuando Cloud Scheduler genera estos errores
- Solución: Ejecutar `./reparar_proyecto.sh climas-chileno`

#### 2. Error 404 en Weather API

**Qué significa**: La Weather API no encontró el endpoint

**Causa común**: Código desactualizado usando método POST en vez de GET

**Cómo verificar si ya está arreglado**:
```bash
# Si ves este comando en el código actual, está bien:
grep "requests.get" extractor/main.py

# Si ves esto, necesitas actualizar:
grep "sesion_autorizada.post" extractor/main.py
```

**Solución**: Redesplegar con el código actualizado

#### 3. Logs Antiguos vs Nuevos

Los logs se ordenan por tiempo. **Los errores más recientes están arriba**.

Para ver solo logs recientes:
```bash
gcloud functions logs read extractor-clima \
    --gen2 \
    --region=us-central1 \
    --limit=10 \
    --project=climas-chileno
```

## Scripts de Verificación

### 1. Verificación Completa End-to-End

```bash
./verificar_flujo_completo.sh climas-chileno
```

Este script verifica:
- ✓ Logs del extractor
- ✓ Logs del procesador
- ✓ Archivos en Cloud Storage
- ✓ Datos en BigQuery
- ✓ Estado del Scheduler
- ✓ Pub/Sub

### 2. Probar Extractor Manualmente

```bash
./probar_extractor_manual.sh climas-chileno
```

Ejecuta el extractor con autenticación correcta y muestra el resultado.

### 3. Verificar Solo el Extractor

```bash
./verificar_extractor.sh
```

Verifica configuración del extractor, Secret Manager y hace una prueba.

### 4. Reparar Permisos

```bash
./reparar_proyecto.sh climas-chileno us-central1
```

Repara automáticamente:
- Permisos IAM faltantes
- Permisos del secret
- Permisos de Cloud Run

## Flujo de Datos Completo

```
Cloud Scheduler (cada hora)
    ↓
Extractor Cloud Function
    ↓ (obtiene API Key de Secret Manager)
    ↓ (llama Weather API con GET)
    ↓
Pub/Sub Topic (clima-datos-crudos)
    ↓
Procesador Cloud Function
    ↓
    ├→ Cloud Storage (Bronze: archivos JSON raw)
    └→ BigQuery (Silver: tabla estructurada)
```

## Verificar que Todo Funciona

### Paso 1: Ejecutar el Scheduler Manualmente

```bash
gcloud scheduler jobs run extraer-clima-job --location=us-central1
```

### Paso 2: Esperar 30-60 segundos

Los mensajes necesitan tiempo para procesarse a través de Pub/Sub.

### Paso 3: Verificar Resultados

```bash
./verificar_flujo_completo.sh climas-chileno
```

Deberías ver:
- ✅ 3 mensajes publicados (Santiago, Farellones, Valparaíso)
- ✅ 3 archivos nuevos en Cloud Storage
- ✅ 3 registros nuevos en BigQuery

## Consultas Útiles de BigQuery

### Ver últimos registros
```sql
SELECT
    nombre_ubicacion,
    temperatura_celsius,
    descripcion_tiempo,
    hora_actual,
    timestamp_ingestion
FROM clima.condiciones_actuales
ORDER BY timestamp_ingestion DESC
LIMIT 10
```

### Contar registros por ubicación
```sql
SELECT
    nombre_ubicacion,
    COUNT(*) as total_registros,
    MIN(hora_actual) as primera_lectura,
    MAX(hora_actual) as ultima_lectura
FROM clima.condiciones_actuales
GROUP BY nombre_ubicacion
ORDER BY nombre_ubicacion
```

### Ver registros de hoy
```sql
SELECT *
FROM clima.condiciones_actuales
WHERE DATE(hora_actual) = CURRENT_DATE('America/Santiago')
ORDER BY hora_actual DESC
```

## Problemas Conocidos

### El scheduler no ejecuta automáticamente

**Verificar estado**:
```bash
gcloud scheduler jobs describe extraer-clima-job \
    --location=us-central1 \
    --project=climas-chileno
```

**Solución**: El scheduler está configurado para ejecutar cada hora (`0 * * * *`). La próxima ejecución será al inicio de la siguiente hora.

### Los datos no aparecen en BigQuery

**Causa más común**: El procesador no se ejecutó

**Verificar logs del procesador**:
```bash
gcloud functions logs read procesador-clima \
    --gen2 \
    --region=us-central1 \
    --limit=20
```

**Verificar mensajes en Pub/Sub**:
```bash
gcloud pubsub subscriptions list --project=climas-chileno
```

### Error de permisos en Secret Manager

**Síntoma**: `Permission denied` al acceder al secret

**Solución**:
```bash
./agregar_permisos_secret.sh climas-chileno
```

O manualmente:
```bash
gcloud secrets add-iam-policy-binding weather-api-key \
    --member="serviceAccount:funciones-clima-sa@climas-chileno.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor" \
    --project=climas-chileno
```

## Contacto y Soporte

Para reportar problemas o hacer preguntas:
1. Ejecuta primero `./verificar_flujo_completo.sh` y guarda la salida
2. Revisa los logs: `gcloud functions logs read extractor-clima --gen2 --region=us-central1 --limit=50`
3. Incluye la salida de ambos comandos en tu reporte
