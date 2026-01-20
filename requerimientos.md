Necesito implementar una integración con la Google Weather API en GCP usando arquitectura event-driven con Pub/Sub.

CONTEXTO:
- Proyecto en Google Cloud Platform
- API: Google Weather API (https://weather.googleapis.com/v1/currentConditions:lookup)
- Autenticación: OAuth 2.0 con scope https://www.googleapis.com/auth/cloud-platform
- Python 3.11
- IMPORTANTE: TODO EL CÓDIGO DEBE ESTAR EN ESPAÑOL (variables, funciones, clases, comentarios, documentación)

ARQUITECTURA REQUERIDA:
Cloud Scheduler → Cloud Function (Extractor) → Pub/Sub Topic → Cloud Function (Procesador) → BigQuery + Cloud Storage

UBICACIONES A MONITOREAR:
- Santiago, Chile (-33.4489, -70.6693)
- Farellones, Chile (-33.3558, -70.2989)
- Valparaíso, Chile (-33.0472, -71.6127)

COMPONENTES A CREAR:

1. /extractor/main.py
   - Cloud Function con HTTP trigger
   - Función principal: extraer_clima()
   - Llamar a currentConditions:lookup para cada ubicación
   - Usar credentials de Application Default Credentials
   - Parámetros: location (LatLng), unitsSystem=METRIC, languageCode=es
   - Publicar cada respuesta a Pub/Sub topic "clima-datos-crudos"
   - Incluir metadata: marca_tiempo, nombre_ubicacion, coordenadas
   - Variables en español: ubicaciones, cliente_publicador, ruta_topic, datos_clima, etc.
   - Comentarios y docstrings en español

2. /extractor/requirements.txt
   - functions-framework
   - google-cloud-pubsub
   - google-auth
   - requests

3. /procesador/main.py
   - Cloud Function con Pub/Sub trigger (topic: clima-datos-crudos)
   - Función principal: procesar_clima()
   - Procesar mensaje recibido
   - Guardar datos crudos en GCS: gs://datos-clima-bronce/{ubicacion}/{AAAA/MM/DD}/{marca_tiempo}.json
   - Transformar y guardar en BigQuery tabla clima.condiciones_actuales con campos:
     * nombre_ubicacion, latitud, longitud
     * hora_actual, zona_horaria
     * temperatura, sensacion_termica, punto_rocio, indice_calor, sensacion_viento
     * condicion_clima, descripcion_clima
     * probabilidad_precipitacion, precipitacion_acumulada
     * presion_aire, velocidad_viento, direccion_viento
     * visibilidad, humedad_relativa, indice_uv
     * probabilidad_tormenta, cobertura_nubes
     * es_dia
     * datos_json_crudo
   - Funciones auxiliares: guardar_en_gcs(), guardar_en_bigquery(), transformar_datos()
   - Variables en español: mensaje_pubsub, datos_clima, fila_bq, cliente_storage, etc.

4. /procesador/requirements.txt
   - functions-framework
   - google-cloud-storage
   - google-cloud-bigquery

5. /terraform/main.tf (opcional)
   - Resources con nombres en español donde sea posible
   - Topics: clima-datos-crudos, clima-datos-procesados
   - Buckets: datos-clima-bronce
   - Dataset: clima
   - Tabla: condiciones_actuales
   - Scheduler: extraer-clima-job
   - Comentarios en español

6. /desplegar.sh
   - Script para deploy de ambas Cloud Functions
   - Comandos gcloud para crear infraestructura
   - Variables y comentarios en español
   - Nombres de funciones: extractor-clima, procesador-clima

7. README.md
   - Documentación completamente en español
   - Secciones: Descripción, Arquitectura, Requisitos Previos, Configuración, Despliegue, Uso
   - Diagramas y explicaciones en español

CONSIDERACIONES TÉCNICAS:
- Usar arquitectura medallion (bronce en GCS, plata en BigQuery)
- Particionar BigQuery por DATE(hora_actual)
- Clusterizar BigQuery por nombre_ubicacion
- Manejo de errores y lógica de reintentos
- Logging estructurado para depuración
- Dead letter queue para mensajes fallidos
- Todas las excepciones personalizadas en español (ej: ErrorExtraccionClima, ErrorPublicacionPubSub)

ESTÁNDARES DE CÓDIGO:
- Nombres de variables descriptivos en español: temperatura_actual, datos_meteorologicos, configuracion_api
- Nombres de funciones en infinitivo: extraer_clima(), procesar_mensaje(), guardar_datos()
- Nombres de clases en PascalCase español: ConfiguracionClima, MensajeClima, DatosMeteorologicos
- Constantes en MAYUSCULAS: UBICACIONES_MONITOREO, ID_PROYECTO, NOMBRE_TOPIC
- Docstrings completos en español con descripción, Args, Returns, Raises
- Comentarios explicativos en español
- Mensajes de log en español

EJEMPLO DE ESTILO ESPERADO:
```python
def extraer_clima(solicitud):
    """
    Extrae datos climáticos de la API de Google Weather para ubicaciones configuradas.
    
    Args:
        solicitud: Objeto HTTP request de Cloud Functions
        
    Returns:
        dict: Diccionario con estado de extracción y detalles de mensajes publicados
        
    Raises:
        ErrorExtraccionClima: Si falla la llamada a la API
        ErrorPublicacionPubSub: Si falla la publicación del mensaje
    """
    ubicaciones = obtener_ubicaciones_monitoreo()
    cliente_publicador = pubsub_v1.PublisherClient()
    # ... resto del código
```

Genera el código completo con buenas prácticas, siguiendo convenciones de nombres en español y documentación inline exhaustiva.
