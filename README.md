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
│ • API Key authentication    │
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

El sistema monitorea **20 ubicaciones** distribuidas de norte a sur de Chile, incluyendo principales ciudades y destinos turísticos:

### Zona Norte Grande
| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **Arica** | -18.4746 | -70.2979 | Ciudad de la Eterna Primavera |
| **Iquique** | -20.2307 | -70.1355 | Playas y Zona Franca |
| **San Pedro de Atacama** | -22.9098 | -68.1995 | Desierto y Turismo Astronómico |

### Zona Norte Chico
| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **La Serena** | -29.9027 | -71.2519 | Playas y Valle del Elqui |

### Zona Central
| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **Viña del Mar** | -33.0246 | -71.5516 | Ciudad Jardín |
| **Valparaíso** | -33.0472 | -71.6127 | Puerto Principal y Patrimonio UNESCO |
| **Santiago** | -33.4489 | -70.6693 | Capital y Región Metropolitana |
| **Farellones** | -33.3558 | -70.2989 | Centro de Esquí Cordillera |
| **Pichilemu** | -34.3870 | -72.0033 | Capital del Surf |

### Zona Sur
| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **Concepción** | -36.8270 | -73.0498 | Capital del Biobío |
| **Temuco** | -38.7359 | -72.5904 | Puerta de La Araucanía |
| **Pucón** | -39.2819 | -71.9755 | Turismo Aventura y Volcán Villarrica |
| **Valdivia** | -39.8142 | -73.2459 | Ciudad de los Ríos |
| **Puerto Varas** | -41.3194 | -72.9833 | Región de los Lagos |
| **Puerto Montt** | -41.4693 | -72.9424 | Puerta de la Patagonia |
| **Castro** | -42.4827 | -73.7622 | Palafitos y Cultura Chilota |

### Zona Austral
| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **Coyhaique** | -45.5752 | -72.0662 | Capital de Aysén |
| **Puerto Natales** | -51.7283 | -72.5085 | Acceso Torres del Paine |
| **Punta Arenas** | -53.1638 | -70.9171 | Ciudad Austral del Estrecho |

### Territorio Insular
| Ubicación | Latitud | Longitud | Descripción |
|-----------|---------|----------|-------------|
| **Isla de Pascua** | -27.1127 | -109.3497 | Rapa Nui - Patrimonio UNESCO |

## Características Técnicas

### Cloud Function: Extractor

- **Trigger**: HTTP (invocado por Cloud Scheduler)
- **Runtime**: Python 3.11
- **Memoria**: 256 MB
- **Timeout**: 60 segundos
- **Funcionalidades**:
  - Autenticación con API Key desde Secret Manager
  - Llamadas GET a Weather API para múltiples ubicaciones
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
- Secret Manager API
- Weather API

### Weather API Key

**IMPORTANTE**: Necesitas una API Key con acceso a la Weather API:

1. Ve a [Google Cloud Console - API Credentials](https://console.cloud.google.com/apis/credentials)
2. Crea una API Key o usa una existente
3. Asegúrate de que la API Key tenga acceso a `weather.googleapis.com`
4. Durante el despliegue, se te solicitará agregar esta API Key a Secret Manager

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

gcloud auth list
gcloud config list project

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
2. ✓ Habilita APIs necesarias (incluyendo Weather API y Secret Manager)
3. ✓ Crea cuenta de servicio y asigna permisos
4. ✓ Configura Secret Manager para Weather API Key
5. ✓ Crea topics de Pub/Sub (principal y DLQ)
6. ✓ Crea bucket de Cloud Storage con ciclo de vida
7. ✓ Crea dataset y tabla de BigQuery
8. ✓ Despliega Cloud Function Extractor
9. ✓ Despliega Cloud Function Procesador
10. ✓ Configura Cloud Scheduler (ejecución cada hora)

**Tiempo estimado**: 5-10 minutos

**Nota**: El script pausará para que agregues tu Weather API Key a Secret Manager. Sigue las instrucciones en pantalla.

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

## Verificar Despliegue

Después del despliegue, verifica que todo funcione correctamente:

```bash
# 1. Ejecutar el scheduler manualmente
gcloud scheduler jobs run extraer-clima-job --location=us-central1

# 2. Esperar 60 segundos para que los mensajes se procesen
sleep 60

# 3. Verificar datos en BigQuery
bq query --use_legacy_sql=false \
  "SELECT nombre_ubicacion, temperatura, descripcion_clima, hora_actual
   FROM clima.condiciones_actuales
   ORDER BY hora_actual DESC
   LIMIT 5"

# 4. Verificar archivos en Cloud Storage
gsutil ls gs://climas-chileno-datos-clima-bronce/**/*.json | head -10
```

## Uso

### Ejecución Manual

Para probar el sistema manualmente con autenticación:

```bash
# Obtener URL del extractor
URL_EXTRACTOR=$(gcloud functions describe extractor-clima \
  --gen2 --region=$REGION --format='value(serviceConfig.uri)')

# Ejecutar extractor con autenticación
curl -X POST $URL_EXTRACTOR \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)"
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

#### Gradiente climático de Norte a Sur (última medición)

```sql
SELECT
  nombre_ubicacion,
  latitud,
  temperatura,
  humedad_relativa,
  velocidad_viento,
  descripcion_clima,
  hora_actual
FROM
  `clima.condiciones_actuales`
WHERE
  hora_actual = (SELECT MAX(hora_actual) FROM `clima.condiciones_actuales`)
ORDER BY
  latitud DESC  -- De norte (latitud menos negativa) a sur (más negativa)
```

#### Comparación de temperaturas extremas por región

```sql
WITH ultima_hora AS (
  SELECT MAX(hora_actual) AS max_hora
  FROM `clima.condiciones_actuales`
)
SELECT
  CASE
    WHEN latitud > -23 THEN 'Norte Grande'
    WHEN latitud > -32 THEN 'Norte Chico'
    WHEN latitud > -38 THEN 'Zona Central'
    WHEN latitud > -44 THEN 'Zona Sur'
    ELSE 'Zona Austral'
  END AS region,
  COUNT(DISTINCT nombre_ubicacion) AS ciudades,
  ROUND(AVG(temperatura), 1) AS temp_promedio,
  ROUND(MIN(temperatura), 1) AS temp_minima,
  ROUND(MAX(temperatura), 1) AS temp_maxima
FROM
  `clima.condiciones_actuales`
CROSS JOIN
  ultima_hora
WHERE
  hora_actual = ultima_hora.max_hora
GROUP BY
  region
ORDER BY
  temp_promedio DESC
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

Estimación mensual para **20 ubicaciones** con ejecución cada hora (730 invocaciones/mes):

| Servicio | Uso | Costo Estimado (USD) |
|----------|-----|----------------------|
| Cloud Functions | 1,460 invocaciones (2 funciones) | $0.05 |
| Pub/Sub | ~14,600 mensajes (20 ubicaciones × 730) | $0.02 |
| Cloud Storage | ~1 GB mensual (14,600 archivos JSON) | $0.02 |
| BigQuery | ~100 MB almacenado/mes | $0.01 |
| BigQuery | ~500 MB queries/mes | $0.01 |
| Cloud Scheduler | 1 job | $0.10 |
| Secret Manager | 1 secret, ~730 accesos/mes | $0.01 |
| **TOTAL** | | **~$0.22/mes** |

**Nota**:
- Los costos son aproximados y pueden variar según el uso real y la región
- Primer año incluye $300 de créditos gratuitos de GCP
- Muchos servicios tienen tier gratuito que cubre este volumen de uso
- Estimación basada en precios de us-central1 (Enero 2026)

## Estructura del Proyecto

```
clima_chileno_gcp/
├── extractor/
│   ├── main.py                 # Cloud Function de extracción
│   ├── requirements.txt        # Dependencias del extractor
│   └── .gcloudignore          # Archivos a ignorar en deploy
├── procesador/
│   ├── main.py                 # Cloud Function de procesamiento
│   ├── requirements.txt        # Dependencias del procesador
│   └── .gcloudignore          # Archivos a ignorar en deploy
├── desplegar.sh                # Script de despliegue automatizado (único punto de entrada)
├── .gcloudignore              # Archivos a ignorar en deploy general
├── .gitignore                  # Archivos a ignorar en git
├── requerimientos.md           # Requerimientos técnicos del proyecto
└── README.md                   # Este archivo (documentación completa)
```

## Solución de Problemas

### Error: Cloud Scheduler "The request was not authenticated"

**Síntoma**: Cloud Scheduler no puede invocar Cloud Function Gen2

**Causa**: Problema con permisos de Cloud Run (Cloud Functions Gen2 corre sobre Cloud Run)

**Solución**:
```bash
# 1. Agregar permisos de Cloud Run a la cuenta de servicio
gcloud run services add-iam-policy-binding extractor-clima \
  --region=us-central1 \
  --member="serviceAccount:funciones-clima-sa@climas-chileno.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

# 2. Verificar con ejecución manual
gcloud scheduler jobs run extraer-clima-job --location=us-central1

# 3. Ver logs para confirmar
gcloud functions logs read extractor-clima --gen2 --region=us-central1 --limit=20
```

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
