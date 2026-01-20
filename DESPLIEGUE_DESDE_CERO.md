# Guía de Despliegue desde Cero

Esta guía te permite desplegar el sistema completo desde cero en un proyecto de GCP nuevo.

## Requisitos Previos

### 1. Weather API Key

Necesitas una API Key con acceso a la Weather API de Google:

```bash
# Listar API Keys existentes
gcloud alpha services api-keys list --project=TU_PROYECTO

# Ver detalles de una API Key específica (reemplaza KEY_ID)
gcloud alpha services api-keys describe KEY_ID --project=TU_PROYECTO

# Obtener el string de la API Key
gcloud alpha services api-keys get-key-string KEY_ID --project=TU_PROYECTO
```

Si no tienes una, créala en [Google Cloud Console - API Credentials](https://console.cloud.google.com/apis/credentials).

### 2. Proyecto de GCP

```bash
# Crear proyecto nuevo (opcional)
gcloud projects create TU_PROYECTO_ID --name="Clima Chileno"

# Habilitar facturación (requerido)
# Esto debe hacerse desde la consola web

# Autenticarse
gcloud auth login
gcloud auth application-default login

# Configurar proyecto
gcloud config set project TU_PROYECTO_ID
```

## Despliegue

### Paso 1: Clonar el repositorio

```bash
git clone https://github.com/fpenailillo/clima_chileno_gcp.git
cd clima_chileno_gcp
```

### Paso 2: Ejecutar script de despliegue

```bash
./desplegar.sh TU_PROYECTO_ID us-central1
```

El script realizará automáticamente:

1. ✓ Habilitación de todas las APIs necesarias
2. ✓ Creación de cuenta de servicio con permisos
3. ✓ Configuración de Secret Manager
4. ✓ Creación de topics de Pub/Sub
5. ✓ Creación de bucket de Cloud Storage
6. ✓ Creación de dataset y tabla de BigQuery
7. ✓ Despliegue de Cloud Functions (Extractor y Procesador)
8. ✓ Configuración de Cloud Scheduler

### Paso 3: Agregar API Key

Durante el despliegue, el script pausará y te mostrará instrucciones como:

```
⚠️  ACCIÓN REQUERIDA: Debes agregar tu Weather API Key al secret

Agrega el valor al secret:
  echo -n 'TU_API_KEY_AQUI' | gcloud secrets versions add weather-api-key --data-file=- --project=TU_PROYECTO

Presiona ENTER cuando hayas agregado la API Key al secret...
```

Ejecuta el comando proporcionado con tu API Key real y presiona ENTER.

### Paso 4: Verificar despliegue

```bash
# 1. Ejecutar el scheduler manualmente
gcloud scheduler jobs run extraer-clima-job --location=us-central1

# 2. Esperar 60 segundos
sleep 60

# 3. Verificar datos en BigQuery
bq query --use_legacy_sql=false \
  "SELECT nombre_ubicacion, temperatura, descripcion_clima, hora_actual
   FROM clima.condiciones_actuales
   ORDER BY hora_actual DESC
   LIMIT 5"

# 4. Verificar archivos en Cloud Storage
gsutil ls gs://TU_PROYECTO-datos-clima-bronce/**/*.json | head -10
```

## Resultados Esperados

### BigQuery

Deberías ver **20 registros** (uno por cada ubicación):

```
+----------------------+-------------+--------------------+---------------------+
| nombre_ubicacion     | temperatura | descripcion_clima  | hora_actual         |
+----------------------+-------------+--------------------+---------------------+
| Arica                | 28.5        | Sunny              | 2026-01-20 13:00:00 |
| Iquique              | 26.3        | Clear              | 2026-01-20 13:00:00 |
| San Pedro de Atacama | 24.1        | Sunny              | 2026-01-20 13:00:00 |
| La Serena            | 22.8        | Partly Cloudy      | 2026-01-20 13:00:00 |
| Viña del Mar         | 21.5        | Cloudy             | 2026-01-20 13:00:00 |
| Santiago             | 25.5        | Sunny              | 2026-01-20 13:00:00 |
| Farellones           | 10.2        | Partly Cloudy      | 2026-01-20 13:00:00 |
| Pucón                | 18.3        | Rainy              | 2026-01-20 13:00:00 |
| Puerto Varas         | 14.7        | Cloudy             | 2026-01-20 13:00:00 |
| Punta Arenas         | 8.2         | Windy              | 2026-01-20 13:00:00 |
| ... (10 más)         | ...         | ...                | ...                 |
+----------------------+-------------+--------------------+---------------------+
```

### Cloud Storage

Deberías ver **20 archivos JSON** con los datos crudos (uno por ubicación por hora).

### Cloud Scheduler

El scheduler ejecutará automáticamente cada hora (`0 * * * *`).

## Estructura de Archivos (Versión Final)

```
clima_chileno_gcp/
├── extractor/
│   ├── main.py              # Función de extracción con API Key
│   ├── requirements.txt     # google-cloud-secret-manager, requests, etc.
│   └── .gcloudignore
├── procesador/
│   ├── main.py              # Función de procesamiento con estructura real de API
│   ├── requirements.txt     # google-cloud-storage, google-cloud-bigquery
│   └── .gcloudignore
├── desplegar.sh             # ⭐ ÚNICO SCRIPT NECESARIO
├── README.md                # Documentación completa
├── requerimientos.md        # Requerimientos técnicos
├── .gitignore
└── .gcloudignore
```

## Solución de Problemas Comunes

### Error: "The request was not authenticated"

```bash
# Agregar permisos de Cloud Run
gcloud run services add-iam-policy-binding extractor-clima \
  --region=us-central1 \
  --member="serviceAccount:funciones-clima-sa@TU_PROYECTO.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

### Error: "Table not found"

La tabla se crea automáticamente con el schema correcto en desplegar.sh. Si la eliminaste, vuelve a ejecutar:

```bash
./desplegar.sh TU_PROYECTO_ID us-central1
```

### Ver Logs

```bash
# Logs del extractor
gcloud functions logs read extractor-clima --gen2 --region=us-central1 --limit=20

# Logs del procesador
gcloud functions logs read procesador-clima --gen2 --region=us-central1 --limit=20
```

## Cambios Principales vs Versión Inicial

### ✅ Autenticación
- **Antes**: OAuth 2.0 (no funcionaba con Weather API)
- **Ahora**: API Key desde Secret Manager

### ✅ Método HTTP
- **Antes**: POST
- **Ahora**: GET con query parameters

### ✅ Extracción de Datos
- **Antes**: Paths incorrectos (ej: `temperature.value`)
- **Ahora**: Paths correctos según [documentación oficial](https://developers.google.com/maps/documentation/weather/currentConditions) (ej: `temperature.degrees`)

### ✅ Schema de BigQuery
- **Antes**: Nombres incorrectos (`temperatura_celsius`, `timestamp_ingestion`)
- **Ahora**: Nombres correctos (`temperatura`, `marca_tiempo_ingestion`)

### ✅ Permisos
- **Antes**: Faltaban permisos de Cloud Run y Secret Manager
- **Ahora**: Todos los permisos incluidos automáticamente

### ✅ Simplicidad
- **Antes**: Múltiples scripts auxiliares
- **Ahora**: Un solo script (`desplegar.sh`)

## Resumen de Comandos

```bash
# Despliegue completo desde cero
git clone https://github.com/fpenailillo/clima_chileno_gcp.git
cd clima_chileno_gcp
./desplegar.sh climas-chileno us-central1

# Durante el despliegue, cuando se solicite:
echo -n 'TU_API_KEY' | gcloud secrets versions add weather-api-key --data-file=- --project=climas-chileno

# Verificar
gcloud scheduler jobs run extraer-clima-job --location=us-central1
sleep 60
bq query --use_legacy_sql=false "SELECT * FROM clima.condiciones_actuales ORDER BY hora_actual DESC LIMIT 5"
```

## Soporte

Para problemas o preguntas, revisa el README.md o abre un issue en el repositorio.

---

**Versión**: 2.0.0
**Última actualización**: 2026-01-20
**Estado**: ✅ Probado y funcionando
