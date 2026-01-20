"""
Procesador de Datos Climáticos - Cloud Function Pub/Sub

Cloud Function que procesa datos climáticos desde Pub/Sub, los almacena
en Cloud Storage (capa bronce) y BigQuery (capa plata) siguiendo
arquitectura medallion.

Arquitectura: Pub/Sub Topic → Cloud Function (Procesador) → BigQuery + Cloud Storage
"""

import base64
import json
import logging
import os
from datetime import datetime, timezone
from typing import Dict, Any, Optional, List

import functions_framework
from google.cloud import storage
from google.cloud import bigquery
from google.cloud.exceptions import GoogleCloudError


# Configuración de logging estructurado
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# Constantes de configuración
# IMPORTANTE: GCP_PROJECT debe ser el NOMBRE del proyecto (ej: 'climas-chileno')
# no el ID numérico (ej: '247279804834'). BigQuery requiere el nombre del proyecto.
ID_PROYECTO = os.environ.get('GCP_PROJECT', os.environ.get('GOOGLE_CLOUD_PROJECT', ''))
NOMBRE_BUCKET = os.environ.get('BUCKET_CLIMA', 'datos-clima-bronce')
NOMBRE_DATASET = os.environ.get('DATASET_CLIMA', 'clima')
NOMBRE_TABLA = os.environ.get('TABLA_CLIMA', 'condiciones_actuales')


class ErrorProcesamientoClima(Exception):
    """Excepción levantada cuando falla el procesamiento de datos climáticos."""
    pass


class ErrorAlmacenamientoGCS(Exception):
    """Excepción levantada cuando falla el almacenamiento en Cloud Storage."""
    pass


class ErrorAlmacenamientoBigQuery(Exception):
    """Excepción levantada cuando falla el almacenamiento en BigQuery."""
    pass


class ErrorValidacionDatos(Exception):
    """Excepción levantada cuando los datos recibidos son inválidos."""
    pass


def decodificar_mensaje_pubsub(mensaje_pubsub: Dict[str, Any]) -> Dict[str, Any]:
    """
    Decodifica el mensaje de Pub/Sub y extrae los datos.

    Args:
        mensaje_pubsub: Mensaje recibido de Pub/Sub

    Returns:
        dict: Datos decodificados del mensaje

    Raises:
        ErrorValidacionDatos: Si el mensaje no se puede decodificar
    """
    try:
        # El mensaje viene en base64
        datos_codificados = mensaje_pubsub.get('data', '')
        if not datos_codificados:
            raise ErrorValidacionDatos("Mensaje Pub/Sub sin datos")

        # Decodificar de base64
        datos_json = base64.b64decode(datos_codificados).decode('utf-8')

        # Parsear JSON
        datos = json.loads(datos_json)

        logger.info(f"Mensaje decodificado exitosamente para ubicación: {datos.get('nombre_ubicacion', 'desconocida')}")

        return datos

    except json.JSONDecodeError as e:
        mensaje_error = f"Error al parsear JSON del mensaje: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorValidacionDatos(mensaje_error)

    except Exception as e:
        mensaje_error = f"Error al decodificar mensaje Pub/Sub: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorValidacionDatos(mensaje_error)


def validar_datos_clima(datos: Dict[str, Any]) -> None:
    """
    Valida que los datos climáticos tengan la estructura esperada.

    Args:
        datos: Datos climáticos a validar

    Raises:
        ErrorValidacionDatos: Si los datos no tienen la estructura correcta
    """
    campos_requeridos = [
        'nombre_ubicacion',
        'coordenadas',
        'datos_clima_raw',
        'marca_tiempo_extraccion'
    ]

    for campo in campos_requeridos:
        if campo not in datos:
            raise ErrorValidacionDatos(f"Campo requerido faltante: {campo}")

    # Validar coordenadas
    coordenadas = datos.get('coordenadas', {})
    if 'latitud' not in coordenadas or 'longitud' not in coordenadas:
        raise ErrorValidacionDatos("Coordenadas incompletas")

    logger.info("Validación de datos completada exitosamente")


def construir_ruta_gcs(datos: Dict[str, Any]) -> str:
    """
    Construye la ruta de almacenamiento en GCS siguiendo estructura de particiones.

    Formato: {ubicacion}/{AAAA}/{MM}/{DD}/{timestamp}.json

    Args:
        datos: Datos climáticos procesados

    Returns:
        str: Ruta del archivo en GCS
    """
    try:
        nombre_ubicacion = datos['nombre_ubicacion'].lower().replace(' ', '_')
        marca_tiempo = datetime.fromisoformat(datos['marca_tiempo_extraccion'].replace('Z', '+00:00'))

        # Construir ruta particionada
        ruta = (
            f"{nombre_ubicacion}/"
            f"{marca_tiempo.year:04d}/"
            f"{marca_tiempo.month:02d}/"
            f"{marca_tiempo.day:02d}/"
            f"{marca_tiempo.strftime('%Y%m%d_%H%M%S')}.json"
        )

        logger.info(f"Ruta GCS construida: {ruta}")
        return ruta

    except Exception as e:
        mensaje_error = f"Error al construir ruta GCS: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorAlmacenamientoGCS(mensaje_error)


def guardar_en_gcs(
    cliente_storage: storage.Client,
    nombre_bucket: str,
    datos: Dict[str, Any]
) -> str:
    """
    Guarda los datos crudos en Cloud Storage (capa bronce - medallion architecture).

    Args:
        cliente_storage: Cliente de Cloud Storage
        nombre_bucket: Nombre del bucket de destino
        datos: Datos a almacenar

    Returns:
        str: URI completa del archivo guardado (gs://bucket/ruta)

    Raises:
        ErrorAlmacenamientoGCS: Si falla el almacenamiento
    """
    try:
        bucket = cliente_storage.bucket(nombre_bucket)
        ruta_archivo = construir_ruta_gcs(datos)
        blob = bucket.blob(ruta_archivo)

        # Convertir a JSON con formato legible
        datos_json = json.dumps(datos, ensure_ascii=False, indent=2)

        # Guardar con metadata
        blob.metadata = {
            'ubicacion': datos.get('nombre_ubicacion', 'desconocida'),
            'marca_tiempo_extraccion': datos.get('marca_tiempo_extraccion', ''),
            'tipo': 'datos_clima_bruto',
            'version_procesador': '1.0.0'
        }

        # Subir archivo
        blob.upload_from_string(
            datos_json,
            content_type='application/json'
        )

        uri_completa = f"gs://{nombre_bucket}/{ruta_archivo}"
        logger.info(f"Datos guardados exitosamente en GCS: {uri_completa}")

        return uri_completa

    except GoogleCloudError as e:
        mensaje_error = f"Error de Google Cloud al guardar en GCS: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorAlmacenamientoGCS(mensaje_error)

    except Exception as e:
        mensaje_error = f"Error inesperado al guardar en GCS: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorAlmacenamientoGCS(mensaje_error)


def extraer_valor_seguro(datos: Dict[str, Any], ruta: List[str], predeterminado: Any = None) -> Any:
    """
    Extrae un valor de un diccionario anidado de forma segura.

    Args:
        datos: Diccionario de datos
        ruta: Lista con la ruta de claves a seguir
        predeterminado: Valor predeterminado si no se encuentra

    Returns:
        Any: Valor encontrado o predeterminado
    """
    actual = datos
    for clave in ruta:
        if isinstance(actual, dict) and clave in actual:
            actual = actual[clave]
        else:
            return predeterminado
    return actual


def transformar_datos_para_bigquery(datos: Dict[str, Any], uri_gcs: str) -> Dict[str, Any]:
    """
    Transforma los datos crudos al esquema de BigQuery (capa plata - medallion architecture).

    Args:
        datos: Datos crudos del clima
        uri_gcs: URI del archivo en GCS

    Returns:
        dict: Datos transformados para BigQuery

    Raises:
        ErrorProcesamientoClima: Si falla la transformación
    """
    try:
        datos_clima_raw = datos.get('datos_clima_raw', {})
        coordenadas = datos.get('coordenadas', {})

        # Extraer fecha/hora - Weather API usa 'currentTime'
        fecha_hora_str = extraer_valor_seguro(datos_clima_raw, ['currentTime'], '')
        try:
            fecha_hora = datetime.fromisoformat(fecha_hora_str.replace('Z', '+00:00'))
        except Exception:
            fecha_hora = datetime.now(timezone.utc)

        # Extraer temperatura y métricas relacionadas - Weather API usa 'degrees'
        temperatura_celsius = extraer_valor_seguro(
            datos_clima_raw, ['temperature', 'degrees']
        )
        sensacion_termica = extraer_valor_seguro(
            datos_clima_raw, ['feelsLikeTemperature', 'degrees']
        )
        punto_rocio = extraer_valor_seguro(
            datos_clima_raw, ['dewPoint', 'degrees']
        )
        indice_calor = extraer_valor_seguro(
            datos_clima_raw, ['heatIndex', 'degrees']
        )
        sensacion_viento = extraer_valor_seguro(
            datos_clima_raw, ['windChill', 'degrees']
        )

        # Extraer condiciones climáticas - Weather API usa 'weatherCondition' (singular)
        condicion_clima = extraer_valor_seguro(
            datos_clima_raw, ['weatherCondition', 'type']
        )
        descripcion_clima = extraer_valor_seguro(
            datos_clima_raw, ['weatherCondition', 'description', 'text']
        )

        # Extraer precipitación - Weather API usa estructura anidada
        precipitacion = extraer_valor_seguro(
            datos_clima_raw, ['precipitation', 'qpf', 'quantity']
        )
        probabilidad_precipitacion = extraer_valor_seguro(
            datos_clima_raw, ['precipitation', 'probability', 'percent']
        )

        # Extraer métricas atmosféricas - Weather API estructura
        presion_aire = extraer_valor_seguro(
            datos_clima_raw, ['airPressure', 'meanSeaLevelMillibars']
        )
        humedad_relativa = extraer_valor_seguro(
            datos_clima_raw, ['relativeHumidity']
        )
        visibilidad = extraer_valor_seguro(
            datos_clima_raw, ['visibility', 'distance']
        )

        # Extraer viento - Weather API usa estructura anidada
        velocidad_viento = extraer_valor_seguro(
            datos_clima_raw, ['wind', 'speed', 'value']
        )
        direccion_viento = extraer_valor_seguro(
            datos_clima_raw, ['wind', 'direction', 'degrees']
        )

        # Extraer índice UV - Weather API valor directo
        indice_uv = extraer_valor_seguro(
            datos_clima_raw, ['uvIndex']
        )

        # Extraer nubes y tormentas - Weather API valores directos
        cobertura_nubes = extraer_valor_seguro(
            datos_clima_raw, ['cloudCover']
        )
        probabilidad_tormenta = extraer_valor_seguro(
            datos_clima_raw, ['thunderstormProbability']
        )

        # Determinar si es de día - Weather API usa 'isDaytime'
        es_dia = extraer_valor_seguro(
            datos_clima_raw, ['isDaytime']
        )

        # Construir fila para BigQuery
        fila_bigquery = {
            'nombre_ubicacion': datos.get('nombre_ubicacion'),
            'latitud': coordenadas.get('latitud'),
            'longitud': coordenadas.get('longitud'),

            'hora_actual': fecha_hora.isoformat(),
            'zona_horaria': extraer_valor_seguro(datos_clima_raw, ['timeZone', 'id']),

            'temperatura': temperatura_celsius,
            'sensacion_termica': sensacion_termica,
            'punto_rocio': punto_rocio,
            'indice_calor': indice_calor,
            'sensacion_viento': sensacion_viento,

            'condicion_clima': condicion_clima,
            'descripcion_clima': descripcion_clima,

            'probabilidad_precipitacion': probabilidad_precipitacion,
            'precipitacion_acumulada': precipitacion,

            'presion_aire': presion_aire,
            'velocidad_viento': velocidad_viento,
            'direccion_viento': direccion_viento,

            'visibilidad': visibilidad,
            'humedad_relativa': humedad_relativa,
            'indice_uv': indice_uv,

            'probabilidad_tormenta': probabilidad_tormenta,
            'cobertura_nubes': cobertura_nubes,

            'es_dia': es_dia,

            'marca_tiempo_ingestion': datetime.now(timezone.utc).isoformat(),
            'uri_datos_crudos': uri_gcs,
            'datos_json_crudo': json.dumps(datos_clima_raw, ensure_ascii=False)
        }

        logger.info(f"Datos transformados exitosamente para {datos.get('nombre_ubicacion')}")

        return fila_bigquery

    except Exception as e:
        mensaje_error = f"Error al transformar datos para BigQuery: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorProcesamientoClima(mensaje_error)


def guardar_en_bigquery(
    cliente_bigquery: bigquery.Client,
    nombre_dataset: str,
    nombre_tabla: str,
    fila: Dict[str, Any]
) -> None:
    """
    Guarda los datos transformados en BigQuery (capa plata - medallion architecture).

    Args:
        cliente_bigquery: Cliente de BigQuery
        nombre_dataset: Nombre del dataset
        nombre_tabla: Nombre de la tabla
        fila: Fila de datos a insertar

    Raises:
        ErrorAlmacenamientoBigQuery: Si falla la inserción
    """
    try:
        tabla_id = f"{ID_PROYECTO}.{nombre_dataset}.{nombre_tabla}"

        # Insertar fila
        errores = cliente_bigquery.insert_rows_json(tabla_id, [fila])

        if errores:
            mensaje_error = f"Errores al insertar en BigQuery: {errores}"
            logger.error(mensaje_error)
            raise ErrorAlmacenamientoBigQuery(mensaje_error)

        logger.info(
            f"Datos insertados exitosamente en BigQuery: "
            f"{nombre_dataset}.{nombre_tabla} para {fila.get('nombre_ubicacion')}"
        )

    except ErrorAlmacenamientoBigQuery:
        raise

    except GoogleCloudError as e:
        mensaje_error = f"Error de Google Cloud al insertar en BigQuery: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorAlmacenamientoBigQuery(mensaje_error)

    except Exception as e:
        mensaje_error = f"Error inesperado al guardar en BigQuery: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorAlmacenamientoBigQuery(mensaje_error)


@functions_framework.cloud_event
def procesar_clima(evento_nube):
    """
    Cloud Function principal que procesa mensajes de Pub/Sub con datos climáticos.

    Esta función es disparada por mensajes en el topic 'clima-datos-crudos' y:
    1. Decodifica y valida el mensaje de Pub/Sub
    2. Guarda datos crudos en Cloud Storage (capa bronce)
    3. Transforma datos al esquema de BigQuery
    4. Inserta datos en BigQuery (capa plata)

    Args:
        evento_nube: Evento de Cloud Functions con el mensaje de Pub/Sub

    El mensaje de Pub/Sub debe contener:
        - nombre_ubicacion: Nombre de la ubicación
        - coordenadas: {latitud, longitud}
        - datos_clima_raw: Datos crudos de Weather API
        - marca_tiempo_extraccion: Timestamp ISO 8601

    Arquitectura Medallion:
        - Bronce (GCS): Datos crudos sin transformar
        - Plata (BigQuery): Datos limpios y estructurados para análisis
    """
    logger.info("=" * 60)
    logger.info("Iniciando procesamiento de mensaje Pub/Sub")
    logger.info("=" * 60)

    cliente_storage = None
    cliente_bigquery = None

    try:
        # Extraer datos del evento
        mensaje_pubsub = evento_nube.data

        # Obtener atributos del mensaje
        atributos = mensaje_pubsub.get('message', {}).get('attributes', {})
        ubicacion_msg = atributos.get('ubicacion', 'desconocida')

        logger.info(f"Procesando mensaje para ubicación: {ubicacion_msg}")

        # Decodificar mensaje
        datos = decodificar_mensaje_pubsub(mensaje_pubsub.get('message', {}))

        # Validar datos
        validar_datos_clima(datos)

        nombre_ubicacion = datos.get('nombre_ubicacion', 'desconocida')

        # Crear clientes de GCP
        cliente_storage = storage.Client()
        cliente_bigquery = bigquery.Client()

        # PASO 1: Guardar datos crudos en Cloud Storage (capa bronce)
        logger.info(f"Guardando datos crudos en GCS para {nombre_ubicacion}...")
        uri_gcs = guardar_en_gcs(cliente_storage, NOMBRE_BUCKET, datos)

        # PASO 2: Transformar datos para BigQuery
        logger.info(f"Transformando datos para BigQuery: {nombre_ubicacion}...")
        fila_bigquery = transformar_datos_para_bigquery(datos, uri_gcs)

        # PASO 3: Guardar en BigQuery (capa plata)
        logger.info(f"Guardando datos transformados en BigQuery: {nombre_ubicacion}...")
        guardar_en_bigquery(
            cliente_bigquery,
            NOMBRE_DATASET,
            NOMBRE_TABLA,
            fila_bigquery
        )

        logger.info("=" * 60)
        logger.info(
            f"Procesamiento completado exitosamente para {nombre_ubicacion}"
        )
        logger.info(f"URI GCS: {uri_gcs}")
        logger.info("=" * 60)

    except ErrorValidacionDatos as e:
        logger.error(f"Error de validación: {str(e)}")
        # No reintentar - mensaje inválido
        logger.warning("Mensaje descartado por validación fallida")

    except (ErrorAlmacenamientoGCS, ErrorAlmacenamientoBigQuery) as e:
        logger.error(f"Error de almacenamiento: {str(e)}")
        # Estos errores causan reintento automático por Pub/Sub
        raise

    except ErrorProcesamientoClima as e:
        logger.error(f"Error de procesamiento: {str(e)}")
        raise

    except Exception as e:
        logger.error(f"Error inesperado en procesamiento: {str(e)}", exc_info=True)
        raise

    finally:
        # Cerrar clientes si existen
        if cliente_storage:
            try:
                cliente_storage.close()
            except Exception as e:
                logger.warning(f"Error al cerrar cliente de Storage: {str(e)}")

        if cliente_bigquery:
            try:
                cliente_bigquery.close()
            except Exception as e:
                logger.warning(f"Error al cerrar cliente de BigQuery: {str(e)}")
