# Sistema de Integración con Google Weather API en GCP

Sistema serverless event-driven para la extracción, procesamiento y almacenamiento de datos climáticos de ubicaciones en Chile utilizando la Google Weather API y servicios de Google Cloud Platform.

## Descripción

Este proyecto implementa una arquitectura moderna de datos meteorológicos basada en eventos que:

- **Extrae** datos climáticos de la Google Weather API para ubicaciones configuradas en Chile
- **Procesa** los datos de forma asíncrona usando Pub/Sub como bus de mensajes
- **Almacena** los datos en una arquitectura medallion:
  - **Capa Bronce** (Cloud Storage): Datos crudos sin transformar
  - **Capa Plata** (BigQuery): Datos limpios y estructurados para análisis
- **Orquesta** la extracción periódica mediante Cloud Scheduler

## Arquitectura

```
┌─────────────────┐
│ Cloud Scheduler │ (Cada hora)
└────────┬────────┘
         │
         ▼
┌─────────────────────────────┐
│ Cloud Function: Extractor   │
│ • Llama a Weather API       │
│ • OAuth 2.0 authentication  │
│ • Publica a Pub/Sub         │
└────────┬────────────────────┘
         │
         ▼
┌─────────────────────────────┐
│ Pub/Sub Topic               │
│ • clima-datos-crudos        │
│ • Dead Letter Queue         │
└────────┬────────────────────┘
         │
         ▼
┌─────────────────────────────┐
│ Cloud Function: Procesador  │
│ • Procesa mensajes Pub/Sub  │
│ • Valida y transforma datos │
└────────┬────────────────────┘
         │
         ├──────────────────────┐
         ▼                      ▼
┌──────────────────┐   ┌──────────────────┐
│ Cloud Storage    │   │ BigQuery         │
│ (Capa Bronce)    │   │ (Capa Plata)     │
│ • Datos crudos   │   │ • Datos          │
│ • Particionado   │   │   estructurados  │
│   por fecha      │   │ • Particionado   │
│ • Versionado     │   │ • Clustering     │
└──────────────────┘   └──────────────────┘
```



## Ubicaciones Monitoreadas

El sistema monitorea las siguientes ubicaciones en Chile:

| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **Santiago** | -33.4489 | -70.6693 | Capital de Chile |
| **Farellones** | -33.3558 | -70.2989 | Centro de esquí en la cordillera |
| **Valparaíso** | -33.0472 | -71.6127 | Puerto principal |

## Características Técnicas

### Cloud Function: Extractor

- **Trigger**: HTTP (invocado por Cloud Scheduler)
- **Runtime**: Python 3.11
- **Memoria**: 256 MB
- **Timeout**: 60 segundos
- **Funcionalidades**:
  - Autenticación OAuth 2.0 con Google Weather API
  - Llamadas paralelas para múltiples ubicaciones
  - Enriquecimiento de datos con metadata
  - Publicación a Pub/Sub con atributos para routing
  - Manejo robusto de errores y logging estructurado

### Cloud Function: Procesador

- **Trigger**: Pub/Sub (topic: clima-datos-crudos)
- **Runtime**: Python 3.11
- **Memoria**: 512 MB
- **Timeout**: 120 segundos
- **Funcionalidades**:
  - Decodificación y validación de mensajes
  - Almacenamiento de datos crudos en Cloud Storage
  - Transformación a esquema estructurado
  - Inserción en BigQuery
  - Reintentos automáticos con exponential backoff
  - Dead letter queue para mensajes fallidos

### Cloud Storage (Capa Bronce)

- **Estructura de particiones**: `{ubicacion}/{AAAA}/{MM}/{DD}/{timestamp}.json`
- **Versionado**: Habilitado
- **Ciclo de vida**:
  - 0-30 días: Standard
  - 30-90 días: Nearline
  - 90-365 días: Coldline
  - 365+ días: Eliminación automática

### BigQuery (Capa Plata)

- **Dataset**: `clima`
- **Tabla**: `condiciones_actuales`
- **Particionamiento**: Por `DATE(hora_actual)`
- **Clustering**: Por `nombre_ubicacion`
- **Esquema** (27 campos):
  - Identificación: ubicación, coordenadas
  - Temporal: hora, zona horaria
  - Temperatura: actual, sensación térmica, punto de rocío, índice de calor
  - Condiciones: descripción, código
  - Precipitación: probabilidad, acumulación
  - Viento: velocidad, dirección, sensación de viento
  - Atmosféricas: presión, humedad, visibilidad
  - Otras: índice UV, cobertura de nubes, probabilidad de tormenta
  - Metadata: timestamp de ingesta, URI datos crudos, JSON completo

## Requisitos Previos

### Software Necesario

- **Google Cloud SDK** (gcloud CLI) versión 400+
- **Python** 3.11+
- **Git** para control de versiones

### Cuenta de Google Cloud

1. Proyecto de GCP activo
2. Facturación habilitada
3. Permisos necesarios:
   - Editor de proyecto o roles específicos:
     - Cloud Functions Admin
     - Pub/Sub Admin
     - Storage Admin
     - BigQuery Admin
     - Service Account Admin
     - Cloud Scheduler Admin

### APIs Requeridas

Las siguientes APIs deben estar habilitadas (el script de despliegue las habilita automáticamente):

- Cloud Functions API
- Cloud Build API
- Cloud Scheduler API
- Pub/Sub API
- Cloud Storage API
- BigQuery API
- Cloud Logging API
- Cloud Run API

## Configuración

### 1. Clonar el Repositorio

```bash
git clone https://github.com/fpenailillo/clima_chileno_gcp
cd clima_chileno_gcp
```

### 2. Configurar Variables de Entorno

```bash
export ID_PROYECTO="climas-chileno"
export REGION="us-central1"
```

### 3. Autenticación con GCP

```bash
# Autenticarse con cuenta de GCP
gcloud auth login

# Configurar proyecto
gcloud config set project $ID_PROYECTO

# Configurar credenciales para Application Default Credentials
gcloud auth application-default login
```

## Despliegue

### Opción 1: Script Automatizado (Recomendado)

El script `desplegar.sh` despliega toda la infraestructura automáticamente:

```bash
./desplegar.sh [ID_PROYECTO] [REGION]
```

Ejemplo:

```bash
./desplegar.sh climas-chileno us-central1
```

El script realiza las siguientes acciones:

1. ✓ Valida dependencias
2. ✓ Habilita APIs necesarias
3. ✓ Crea cuenta de servicio y asigna permisos
4. ✓ Crea topics de Pub/Sub (principal y DLQ)
5. ✓ Crea bucket de Cloud Storage con ciclo de vida
6. ✓ Crea dataset y tabla de BigQuery
7. ✓ Despliega Cloud Function Extractor
8. ✓ Despliega Cloud Function Procesador
9. ✓ Configura Cloud Scheduler (ejecución cada hora)

**Tiempo estimado**: 5-10 minutos

### Opción 2: Despliegue Manual

#### 2.1 Crear Topics de Pub/Sub

```bash
gcloud pubsub topics create clima-datos-crudos --project=$ID_PROYECTO
gcloud pubsub topics create clima-datos-dlq --project=$ID_PROYECTO
```

#### 2.2 Crear Bucket de Cloud Storage

```bash
gsutil mb -p $ID_PROYECTO -l $REGION gs://${ID_PROYECTO}-datos-clima-bronce
gsutil versioning set on gs://${ID_PROYECTO}-datos-clima-bronce
```

#### 2.3 Crear Dataset y Tabla de BigQuery

```bash
# Crear dataset
bq mk --project_id=$ID_PROYECTO --location=$REGION clima

# Crear tabla (el schema completo se crea automáticamente con desplegar.sh)
# Aquí se muestra solo la estructura básica
bq mk --project_id=$ID_PROYECTO \
  --table \
  --time_partitioning_field=hora_actual \
  --time_partitioning_type=DAY \
  --clustering_fields=nombre_ubicacion \
  clima.condiciones_actuales
```

#### 2.4 Desplegar Cloud Functions

```bash
# Extractor
gcloud functions deploy extractor-clima \
  --gen2 \
  --runtime=python311 \
  --region=$REGION \
  --source=./extractor \
  --entry-point=extraer_clima \
  --trigger-http \
  --set-env-vars=GCP_PROJECT=$ID_PROYECTO

# Procesador
gcloud functions deploy procesador-clima \
  --gen2 \
  --runtime=python311 \
  --region=$REGION \
  --source=./procesador \
  --entry-point=procesar_clima \
  --trigger-topic=clima-datos-crudos \
  --set-env-vars=GCP_PROJECT=$ID_PROYECTO
```

#### 2.5 Configurar Cloud Scheduler

```bash
# Obtener URL del extractor
URL_EXTRACTOR=$(gcloud functions describe extractor-clima \
  --gen2 --region=$REGION --format='value(serviceConfig.uri)')

# Crear job
gcloud scheduler jobs create http extraer-clima-job \
  --location=$REGION \
  --schedule="0 * * * *" \
  --uri=$URL_EXTRACTOR \
  --http-method=POST
```

## Uso

### Ejecución Manual

Para probar el sistema manualmente:

```bash
# Obtener URL del extractor
URL_EXTRACTOR=$(gcloud functions describe extractor-clima \
  --gen2 --region=$REGION --format='value(serviceConfig.uri)')

# Ejecutar extractor
curl -X POST $URL_EXTRACTOR -H "Authorization: Bearer $(gcloud auth print-identity-token)"
```

### Ejecución Programada

Cloud Scheduler ejecuta automáticamente el extractor cada hora según la configuración:

- **Frecuencia**: `0 * * * *` (cada hora en punto)
- **Zona horaria**: America/Santiago
- **Reintentos**: Hasta 3 intentos con backoff exponencial

### Ver Logs

```bash
# Logs del extractor
gcloud functions logs read extractor-clima --gen2 --region=$REGION --limit=50

# Logs del procesador
gcloud functions logs read procesador-clima --gen2 --region=$REGION --limit=50

# Logs en tiempo real
gcloud functions logs read extractor-clima --gen2 --region=$REGION --tail
```

### Consultar Datos en BigQuery

#### Últimas 10 mediciones

```sql
SELECT
  nombre_ubicacion,
  hora_actual,
  temperatura,
  descripcion_clima,
  humedad_relativa,
  velocidad_viento
FROM
  `clima.condiciones_actuales`
ORDER BY
  hora_actual DESC
LIMIT 10;
```

#### Promedio de temperatura por ubicación (últimas 24 horas)

```sql
SELECT
  nombre_ubicacion,
  AVG(temperatura) AS temperatura_promedio,
  MIN(temperatura) AS temperatura_minima,
  MAX(temperatura) AS temperatura_maxima,
  COUNT(*) AS total_mediciones
FROM
  `clima.condiciones_actuales`
WHERE
  hora_actual >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)
GROUP BY
  nombre_ubicacion
ORDER BY
  nombre_ubicacion;
```

#### Condiciones climáticas más frecuentes

```sql
SELECT
  nombre_ubicacion,
  descripcion_clima,
  COUNT(*) AS frecuencia
FROM
  `clima.condiciones_actuales`
WHERE
  descripcion_clima IS NOT NULL
  AND hora_actual >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY
  nombre_ubicacion,
  descripcion_clima
ORDER BY
  nombre_ubicacion,
  frecuencia DESC;
```

### Explorar Datos Crudos en Cloud Storage

```bash
# Listar archivos recientes
gsutil ls -l gs://${ID_PROYECTO}-datos-clima-bronce/santiago/$(date +%Y)

# Descargar un archivo
gsutil cp gs://${ID_PROYECTO}-datos-clima-bronce/santiago/2024/01/15/20240115_120000.json .

# Ver contenido
cat 20240115_120000.json | jq .
```

## Monitoreo y Alertas

### Métricas Importantes

1. **Cloud Functions**:
   - Tasa de invocaciones
   - Tasa de errores
   - Duración de ejecución
   - Memoria utilizada

2. **Pub/Sub**:
   - Mensajes publicados/procesados
   - Mensajes no confirmados
   - Mensajes en DLQ

3. **BigQuery**:
   - Filas insertadas
   - Bytes procesados
   - Errores de inserción

### Configurar Alertas

Crear alertas en Cloud Monitoring para:

```bash
# Tasa de errores alta en Cloud Functions (>5%)
# Mensajes acumulados en DLQ (>10)
# Falta de datos nuevos en BigQuery (>2 horas sin inserts)
```

Ver [documentación de Cloud Monitoring](https://cloud.google.com/monitoring/docs) para configuración detallada.

## Costos Estimados

Estimación mensual para ejecución cada hora (730 invocaciones/mes):

| Servicio | Uso | Costo Estimado (USD) |
|----------|-----|----------------------|
| Cloud Functions | 1,460 invocaciones | $0.05 |
| Pub/Sub | ~3K mensajes | $0.01 |
| Cloud Storage | 100 GB (bronce) | $2.00 |
| BigQuery | 10 GB almacenado | $0.20 |
| BigQuery | 1 GB queries | $0.01 |
| Cloud Scheduler | 1 job | $0.10 |
| **TOTAL** | | **~$2.37/mes** |

**Nota**: Los costos son aproximados y pueden variar según el uso real y la región.

## Estructura del Proyecto

```
clima_chileno_gcp/
├── extractor/
│   ├── main.py                 # Cloud Function de extracción
│   ├── requirements.txt        # Dependencias del extractor
│   └── .gcloudignore          # Archivos a ignorar en deploy del extractor
├── procesador/
│   ├── main.py                 # Cloud Function de procesamiento
│   ├── requirements.txt        # Dependencias del procesador
│   └── .gcloudignore          # Archivos a ignorar en deploy del procesador
├── desplegar.sh                # Script de despliegue automatizado (ejecutar esto)
├── .gcloudignore              # Archivos a ignorar en deploy general
├── .gitignore                  # Archivos a ignorar en git
└── README.md                   # Este archivo (documentación completa)
```

## Solución de Problemas

### Error: Permisos insuficientes

**Síntoma**: Error 403 o "Permission denied"

**Solución**:
```bash
# Verificar permisos de la cuenta de servicio
gcloud projects get-iam-policy $ID_PROYECTO \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:funciones-clima-sa@"

# Asignar permisos faltantes
gcloud projects add-iam-policy-binding $ID_PROYECTO \
  --member="serviceAccount:funciones-clima-sa@${ID_PROYECTO}.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

### Error: API no habilitada

**Síntoma**: "API [nombre] has not been used in project"

**Solución**:
```bash
# Habilitar API específica
gcloud services enable [nombre-api].googleapis.com --project=$ID_PROYECTO

# Ejemplo
gcloud services enable cloudfunctions.googleapis.com --project=$ID_PROYECTO
```

### Error: Timeout en Cloud Function

**Síntoma**: Function timeout, exceeded time limit

**Solución**:
```bash
# Aumentar timeout del extractor
gcloud functions deploy extractor-clima \
  --gen2 \
  --timeout=120s \
  --region=$REGION

# Aumentar timeout del procesador
gcloud functions deploy procesador-clima \
  --gen2 \
  --timeout=180s \
  --region=$REGION
```

### Mensajes en Dead Letter Queue

**Síntoma**: Mensajes acumulados en topic clima-datos-dlq

**Solución**:
```bash
# Ver mensajes en DLQ
gcloud pubsub subscriptions pull clima-datos-dlq-sub --limit=10

# Revisar logs del procesador para identificar causa
gcloud functions logs read procesador-clima --gen2 --region=$REGION --limit=100

# Reprocesar mensajes manualmente si es necesario
```

## Mejoras Futuras

- [ ] Agregar más ubicaciones monitoreadas
- [ ] Implementar pronóstico extendido (15 días)
- [ ] Crear dashboard en Looker Studio o Data Studio
- [ ] Añadir alertas automáticas por condiciones climáticas extremas
- [ ] Implementar API REST para consultar datos históricos
- [ ] Agregar tests unitarios y de integración
- [ ] Implementar CI/CD con Cloud Build
- [ ] Crear capa Gold en BigQuery con agregaciones pre-calculadas
- [ ] Añadir soporte para múltiples países
- [ ] Implementar caché de datos con Cloud Memorystore

## Estándares de Código

Este proyecto sigue estándares estrictos de código en español:

- **Variables**: `temperatura_actual`, `datos_meteorologicos`
- **Funciones**: `extraer_clima()`, `procesar_mensaje()`, `guardar_datos()`
- **Clases**: `ConfiguracionClima`, `DatosMeteorologicos`
- **Constantes**: `UBICACIONES_MONITOREO`, `ID_PROYECTO`
- **Documentación**: Docstrings completos en español con Args, Returns, Raises
- **Comentarios**: Explicaciones en español
- **Logs**: Mensajes en español

## Contribuir

1. Fork el proyecto
2. Crear rama de feature (`git checkout -b feature/nueva-funcionalidad`)
3. Commit cambios (`git commit -m 'Agregar nueva funcionalidad'`)
4. Push a la rama (`git push origin feature/nueva-funcionalidad`)
5. Crear Pull Request

## Licencia

Este proyecto está bajo la licencia MIT. Ver archivo `LICENSE` para más detalles.

## Contacto

Para preguntas, problemas o sugerencias, por favor abrir un issue en el repositorio.

## Referencias

- [Google Weather API Documentation](https://developers.google.com/maps/documentation/weather)
- [Google Cloud Functions](https://cloud.google.com/functions/docs)
- [Google Cloud Pub/Sub](https://cloud.google.com/pubsub/docs)
- [Google BigQuery](https://cloud.google.com/bigquery/docs)
- [Cloud Scheduler](https://cloud.google.com/scheduler/docs)
- [Arquitectura Medallion](https://www.databricks.com/glossary/medallion-architecture)

---

**Nota**: Este sistema está diseñado para propósitos educativos y de demostración. Para uso en producción, considere implementar autenticación más robusta, monitoreo avanzado, y pruebas exhaustivas.
