"""
Extractor de Datos Climáticos - Google Weather API

Cloud Function HTTP que extrae datos climáticos de la Google Weather API
para ubicaciones configuradas en Chile y publica los datos a Pub/Sub.

Arquitectura: Cloud Scheduler → Cloud Function (Extractor) → Pub/Sub Topic
"""

import json
import logging
import os
from datetime import datetime, timezone
from typing import Dict, List, Any, Tuple

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import pubsub_v1
from flask import Request


# Configuración de logging estructurado
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# Constantes de configuración
ID_PROYECTO = os.environ.get('GCP_PROJECT', os.environ.get('GOOGLE_CLOUD_PROJECT', ''))
NOMBRE_TOPIC = 'clima-datos-crudos'
URL_BASE_API = 'https://weather.googleapis.com/v1/currentConditions:lookup'
SCOPE_API = 'https://www.googleapis.com/auth/cloud-platform'

# Ubicaciones a monitorear en Chile
UBICACIONES_MONITOREO = [
    {
        'nombre': 'Santiago',
        'latitud': -33.4489,
        'longitud': -70.6693,
        'descripcion': 'Santiago, Chile - Capital'
    },
    {
        'nombre': 'Farellones',
        'latitud': -33.3558,
        'longitud': -70.2989,
        'descripcion': 'Farellones, Chile - Centro de Esquí'
    },
    {
        'nombre': 'Valparaíso',
        'latitud': -33.0472,
        'longitud': -71.6127,
        'descripcion': 'Valparaíso, Chile - Puerto Principal'
    }
]


class ErrorExtraccionClima(Exception):
    """Excepción levantada cuando falla la extracción de datos climáticos."""
    pass


class ErrorPublicacionPubSub(Exception):
    """Excepción levantada cuando falla la publicación de mensajes a Pub/Sub."""
    pass


class ErrorConfiguracion(Exception):
    """Excepción levantada cuando hay problemas con la configuración."""
    pass


def obtener_credenciales() -> Tuple[Any, str]:
    """
    Obtiene las credenciales de Google Cloud usando Application Default Credentials.

    Returns:
        Tuple[Any, str]: Tupla con (credenciales, id_proyecto)

    Raises:
        ErrorConfiguracion: Si no se pueden obtener las credenciales
    """
    try:
        credenciales, proyecto = google.auth.default(scopes=[SCOPE_API])
        logger.info(f"Credenciales obtenidas exitosamente para proyecto: {proyecto}")
        return credenciales, proyecto
    except Exception as e:
        mensaje_error = f"Error al obtener credenciales: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorConfiguracion(mensaje_error)


def construir_parametros_solicitud(latitud: float, longitud: float) -> Dict[str, Any]:
    """
    Construye los parámetros para la solicitud a la Weather API.

    Args:
        latitud: Latitud de la ubicación
        longitud: Longitud de la ubicación

    Returns:
        dict: Parámetros formateados para la API
    """
    return {
        'location': {
            'latitude': latitud,
            'longitude': longitud
        },
        'unitsSystem': 'METRIC',
        'languageCode': 'es'
    }


def llamar_weather_api(
    sesion_autorizada: AuthorizedSession,
    latitud: float,
    longitud: float,
    nombre_ubicacion: str
) -> Dict[str, Any]:
    """
    Realiza llamada a la Google Weather API para obtener condiciones actuales.

    Args:
        sesion_autorizada: Sesión HTTP autorizada con OAuth 2.0
        latitud: Latitud de la ubicación
        longitud: Longitud de la ubicación
        nombre_ubicacion: Nombre descriptivo de la ubicación

    Returns:
        dict: Datos climáticos obtenidos de la API

    Raises:
        ErrorExtraccionClima: Si la llamada a la API falla
    """
    try:
        parametros = construir_parametros_solicitud(latitud, longitud)

        logger.info(f"Consultando clima para {nombre_ubicacion} ({latitud}, {longitud})")

        respuesta = sesion_autorizada.post(
            URL_BASE_API,
            json=parametros,
            timeout=30
        )

        if respuesta.status_code != 200:
            mensaje_error = (
                f"Error en API para {nombre_ubicacion}: "
                f"Estado {respuesta.status_code}, Respuesta: {respuesta.text}"
            )
            logger.error(mensaje_error)
            raise ErrorExtraccionClima(mensaje_error)

        datos_clima = respuesta.json()
        logger.info(f"Datos climáticos obtenidos exitosamente para {nombre_ubicacion}")

        return datos_clima

    except ErrorExtraccionClima:
        raise
    except Exception as e:
        mensaje_error = f"Error inesperado al llamar API para {nombre_ubicacion}: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorExtraccionClima(mensaje_error)


def enriquecer_datos_clima(
    datos_clima: Dict[str, Any],
    ubicacion: Dict[str, Any]
) -> Dict[str, Any]:
    """
    Enriquece los datos climáticos con metadata adicional.

    Args:
        datos_clima: Datos crudos de la Weather API
        ubicacion: Información de la ubicación monitoreada

    Returns:
        dict: Datos climáticos enriquecidos con metadata
    """
    marca_tiempo = datetime.now(timezone.utc).isoformat()

    datos_enriquecidos = {
        'marca_tiempo_extraccion': marca_tiempo,
        'nombre_ubicacion': ubicacion['nombre'],
        'coordenadas': {
            'latitud': ubicacion['latitud'],
            'longitud': ubicacion['longitud']
        },
        'descripcion_ubicacion': ubicacion['descripcion'],
        'datos_clima_raw': datos_clima,
        'version_extractor': '1.0.0'
    }

    return datos_enriquecidos


def publicar_a_pubsub(
    cliente_publicador: pubsub_v1.PublisherClient,
    ruta_topic: str,
    datos_mensaje: Dict[str, Any],
    nombre_ubicacion: str
) -> str:
    """
    Publica datos climáticos a un topic de Pub/Sub.

    Args:
        cliente_publicador: Cliente de Pub/Sub Publisher
        ruta_topic: Ruta completa del topic
        datos_mensaje: Datos a publicar
        nombre_ubicacion: Nombre de la ubicación (para logging)

    Returns:
        str: ID del mensaje publicado

    Raises:
        ErrorPublicacionPubSub: Si falla la publicación
    """
    try:
        # Convertir datos a JSON bytes
        mensaje_json = json.dumps(datos_mensaje, ensure_ascii=False)
        mensaje_bytes = mensaje_json.encode('utf-8')

        # Atributos del mensaje para filtrado y routing
        atributos = {
            'ubicacion': nombre_ubicacion,
            'tipo': 'datos_clima',
            'version': '1.0'
        }

        # Publicar mensaje
        futuro = cliente_publicador.publish(
            ruta_topic,
            mensaje_bytes,
            **atributos
        )

        # Esperar confirmación
        id_mensaje = futuro.result(timeout=10)

        logger.info(
            f"Mensaje publicado exitosamente a Pub/Sub para {nombre_ubicacion}. "
            f"ID: {id_mensaje}"
        )

        return id_mensaje

    except Exception as e:
        mensaje_error = f"Error al publicar mensaje para {nombre_ubicacion}: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorPublicacionPubSub(mensaje_error)


def obtener_ubicaciones_monitoreo() -> List[Dict[str, Any]]:
    """
    Obtiene la lista de ubicaciones a monitorear.

    En producción, esto podría venir de Cloud Storage, Firestore, o Secret Manager.
    Por ahora usa la constante UBICACIONES_MONITOREO.

    Returns:
        list: Lista de diccionarios con información de ubicaciones
    """
    return UBICACIONES_MONITOREO


@functions_framework.http
def extraer_clima(solicitud: Request) -> Tuple[Dict[str, Any], int]:
    """
    Cloud Function HTTP principal que extrae datos climáticos y publica a Pub/Sub.

    Esta función es invocada por Cloud Scheduler periódicamente para:
    1. Obtener credenciales OAuth 2.0
    2. Consultar Weather API para cada ubicación configurada
    3. Enriquecer datos con metadata
    4. Publicar a Pub/Sub topic 'clima-datos-crudos'

    Args:
        solicitud: Objeto HTTP request de Cloud Functions

    Returns:
        Tuple[dict, int]: Respuesta JSON y código de estado HTTP

    Ejemplo de respuesta exitosa:
        {
            "estado": "exitoso",
            "total_ubicaciones": 3,
            "mensajes_publicados": 3,
            "detalles": [
                {
                    "ubicacion": "Santiago",
                    "estado": "exitoso",
                    "id_mensaje": "123456789"
                }
            ]
        }
    """
    logger.info("=" * 60)
    logger.info("Iniciando extracción de datos climáticos")
    logger.info("=" * 60)

    resultados = {
        'estado': 'exitoso',
        'total_ubicaciones': 0,
        'mensajes_publicados': 0,
        'mensajes_fallidos': 0,
        'detalles': [],
        'errores': []
    }

    sesion_autorizada = None
    cliente_publicador = None

    try:
        # Validar configuración
        proyecto = ID_PROYECTO
        if not proyecto:
            raise ErrorConfiguracion(
                "ID_PROYECTO no configurado. "
                "Establecer variable de entorno GCP_PROJECT o GOOGLE_CLOUD_PROJECT"
            )

        # Obtener credenciales y crear sesión autorizada
        credenciales, proyecto_detectado = obtener_credenciales()
        if not proyecto:
            proyecto = proyecto_detectado

        sesion_autorizada = AuthorizedSession(credenciales)

        # Crear cliente de Pub/Sub
        cliente_publicador = pubsub_v1.PublisherClient()
        ruta_topic = cliente_publicador.topic_path(proyecto, NOMBRE_TOPIC)

        logger.info(f"Publicando a topic: {ruta_topic}")

        # Obtener ubicaciones a monitorear
        ubicaciones = obtener_ubicaciones_monitoreo()
        resultados['total_ubicaciones'] = len(ubicaciones)

        logger.info(f"Total de ubicaciones a procesar: {len(ubicaciones)}")

        # Procesar cada ubicación
        for ubicacion in ubicaciones:
            nombre_ubicacion = ubicacion['nombre']
            detalle_ubicacion = {
                'ubicacion': nombre_ubicacion,
                'estado': 'pendiente'
            }

            try:
                # Llamar a Weather API
                datos_clima = llamar_weather_api(
                    sesion_autorizada,
                    ubicacion['latitud'],
                    ubicacion['longitud'],
                    nombre_ubicacion
                )

                # Enriquecer datos
                datos_enriquecidos = enriquecer_datos_clima(datos_clima, ubicacion)

                # Publicar a Pub/Sub
                id_mensaje = publicar_a_pubsub(
                    cliente_publicador,
                    ruta_topic,
                    datos_enriquecidos,
                    nombre_ubicacion
                )

                # Registrar éxito
                detalle_ubicacion['estado'] = 'exitoso'
                detalle_ubicacion['id_mensaje'] = id_mensaje
                resultados['mensajes_publicados'] += 1

            except (ErrorExtraccionClima, ErrorPublicacionPubSub) as e:
                # Error específico en esta ubicación
                detalle_ubicacion['estado'] = 'fallido'
                detalle_ubicacion['error'] = str(e)
                resultados['mensajes_fallidos'] += 1
                resultados['errores'].append({
                    'ubicacion': nombre_ubicacion,
                    'error': str(e)
                })
                logger.error(f"Error procesando {nombre_ubicacion}: {str(e)}")

            resultados['detalles'].append(detalle_ubicacion)

        # Determinar estado final
        if resultados['mensajes_fallidos'] == resultados['total_ubicaciones']:
            resultados['estado'] = 'fallido'
            codigo_estado = 500
        elif resultados['mensajes_fallidos'] > 0:
            resultados['estado'] = 'parcial'
            codigo_estado = 207  # Multi-Status
        else:
            resultados['estado'] = 'exitoso'
            codigo_estado = 200

        logger.info("=" * 60)
        logger.info(
            f"Extracción completada: {resultados['mensajes_publicados']} exitosos, "
            f"{resultados['mensajes_fallidos']} fallidos"
        )
        logger.info("=" * 60)

        return resultados, codigo_estado

    except ErrorConfiguracion as e:
        logger.error(f"Error de configuración: {str(e)}")
        return {
            'estado': 'fallido',
            'error': str(e),
            'tipo_error': 'configuracion'
        }, 500

    except Exception as e:
        logger.error(f"Error inesperado en extracción: {str(e)}", exc_info=True)
        return {
            'estado': 'fallido',
            'error': f"Error inesperado: {str(e)}",
            'tipo_error': 'desconocido'
        }, 500

    finally:
        # Cerrar sesión si existe
        if sesion_autorizada:
            try:
                sesion_autorizada.close()
            except Exception as e:
                logger.warning(f"Error al cerrar sesión autorizada: {str(e)}")
