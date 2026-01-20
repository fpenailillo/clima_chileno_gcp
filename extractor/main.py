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
import requests
from google.cloud import pubsub_v1
from google.cloud import secretmanager
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
NOMBRE_SECRET_API_KEY = 'weather-api-key'

# Ubicaciones a monitorear en Chile
# Cobertura de norte a sur del país, incluyendo principales ciudades y destinos turísticos
UBICACIONES_MONITOREO = [
    # ZONA NORTE GRANDE
    {
        'nombre': 'Arica',
        'latitud': -18.4746,
        'longitud': -70.2979,
        'descripcion': 'Arica, Chile - Ciudad de la Eterna Primavera'
    },
    {
        'nombre': 'Iquique',
        'latitud': -20.2307,
        'longitud': -70.1355,
        'descripcion': 'Iquique, Chile - Playas y Zona Franca'
    },
    {
        'nombre': 'San Pedro de Atacama',
        'latitud': -22.9098,
        'longitud': -68.1995,
        'descripcion': 'San Pedro de Atacama, Chile - Desierto y Turismo Astronómico'
    },

    # ZONA NORTE CHICO
    {
        'nombre': 'La Serena',
        'latitud': -29.9027,
        'longitud': -71.2519,
        'descripcion': 'La Serena, Chile - Playas y Valle del Elqui'
    },

    # ZONA CENTRAL
    {
        'nombre': 'Viña del Mar',
        'latitud': -33.0246,
        'longitud': -71.5516,
        'descripcion': 'Viña del Mar, Chile - Ciudad Jardín'
    },
    {
        'nombre': 'Valparaíso',
        'latitud': -33.0472,
        'longitud': -71.6127,
        'descripcion': 'Valparaíso, Chile - Puerto Principal y Patrimonio UNESCO'
    },
    {
        'nombre': 'Santiago',
        'latitud': -33.4489,
        'longitud': -70.6693,
        'descripcion': 'Santiago, Chile - Capital y Región Metropolitana'
    },
    {
        'nombre': 'Farellones',
        'latitud': -33.3558,
        'longitud': -70.2989,
        'descripcion': 'Farellones, Chile - Centro de Esquí Cordillera de Los Andes'
    },
    {
        'nombre': 'Pichilemu',
        'latitud': -34.3870,
        'longitud': -72.0033,
        'descripcion': 'Pichilemu, Chile - Capital del Surf'
    },

    # ZONA SUR
    {
        'nombre': 'Concepción',
        'latitud': -36.8270,
        'longitud': -73.0498,
        'descripcion': 'Concepción, Chile - Capital del Biobío'
    },
    {
        'nombre': 'Temuco',
        'latitud': -38.7359,
        'longitud': -72.5904,
        'descripcion': 'Temuco, Chile - Puerta de La Araucanía'
    },
    {
        'nombre': 'Pucón',
        'latitud': -39.2819,
        'longitud': -71.9755,
        'descripcion': 'Pucón, Chile - Turismo Aventura y Volcán Villarrica'
    },
    {
        'nombre': 'Valdivia',
        'latitud': -39.8142,
        'longitud': -73.2459,
        'descripcion': 'Valdivia, Chile - Ciudad de los Ríos'
    },
    {
        'nombre': 'Puerto Varas',
        'latitud': -41.3194,
        'longitud': -72.9833,
        'descripcion': 'Puerto Varas, Chile - Región de los Lagos'
    },
    {
        'nombre': 'Puerto Montt',
        'latitud': -41.4693,
        'longitud': -72.9424,
        'descripcion': 'Puerto Montt, Chile - Puerta de la Patagonia'
    },
    {
        'nombre': 'Castro',
        'latitud': -42.4827,
        'longitud': -73.7622,
        'descripcion': 'Castro, Chiloé - Palafitos y Cultura Chilota'
    },

    # ZONA AUSTRAL
    {
        'nombre': 'Coyhaique',
        'latitud': -45.5752,
        'longitud': -72.0662,
        'descripcion': 'Coyhaique, Chile - Capital de Aysén'
    },
    {
        'nombre': 'Puerto Natales',
        'latitud': -51.7283,
        'longitud': -72.5085,
        'descripcion': 'Puerto Natales, Chile - Acceso Torres del Paine'
    },
    {
        'nombre': 'Punta Arenas',
        'latitud': -53.1638,
        'longitud': -70.9171,
        'descripcion': 'Punta Arenas, Chile - Ciudad Austral del Estrecho'
    },

    # TERRITORIO INSULAR
    {
        'nombre': 'Isla de Pascua',
        'latitud': -27.1127,
        'longitud': -109.3497,
        'descripcion': 'Isla de Pascua (Rapa Nui), Chile - Patrimonio UNESCO'
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


def obtener_api_key() -> str:
    """
    Obtiene la API Key de Google Weather desde Secret Manager.

    Returns:
        str: API Key para autenticación con Weather API

    Raises:
        ErrorConfiguracion: Si no se puede obtener la API Key
    """
    try:
        cliente_secrets = secretmanager.SecretManagerServiceClient()

        # Construir nombre del secret
        nombre_secret = f"projects/{ID_PROYECTO}/secrets/{NOMBRE_SECRET_API_KEY}/versions/latest"

        # Obtener el secret
        respuesta = cliente_secrets.access_secret_version(request={"name": nombre_secret})
        api_key = respuesta.payload.data.decode('UTF-8')

        logger.info("API Key obtenida exitosamente desde Secret Manager")
        return api_key

    except Exception as e:
        mensaje_error = f"Error al obtener API Key desde Secret Manager: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorConfiguracion(mensaje_error)


def construir_url_api(latitud: float, longitud: float, api_key: str) -> str:
    """
    Construye la URL completa para la llamada a la Weather API.

    Args:
        latitud: Latitud de la ubicación
        longitud: Longitud de la ubicación
        api_key: API Key para autenticación

    Returns:
        str: URL completa con query parameters
    """
    # Construir URL con query parameters
    url = (
        f"{URL_BASE_API}"
        f"?key={api_key}"
        f"&location.latitude={latitud}"
        f"&location.longitude={longitud}"
        f"&languageCode=es"
    )

    return url


def llamar_weather_api(
    latitud: float,
    longitud: float,
    nombre_ubicacion: str,
    api_key: str
) -> Dict[str, Any]:
    """
    Realiza llamada GET a la Google Weather API para obtener condiciones actuales.

    Args:
        latitud: Latitud de la ubicación
        longitud: Longitud de la ubicación
        nombre_ubicacion: Nombre descriptivo de la ubicación
        api_key: API Key para autenticación

    Returns:
        dict: Datos climáticos obtenidos de la API

    Raises:
        ErrorExtraccionClima: Si la llamada a la API falla
    """
    try:
        # Construir URL con query parameters
        url = construir_url_api(latitud, longitud, api_key)

        logger.info(f"Consultando clima para {nombre_ubicacion} ({latitud}, {longitud})")

        # Hacer GET request
        respuesta = requests.get(url, timeout=30)

        if respuesta.status_code != 200:
            mensaje_error = (
                f"Error en API para {nombre_ubicacion}: "
                f"Estado {respuesta.status_code}, Respuesta: {respuesta.text[:500]}"
            )
            logger.error(mensaje_error)
            raise ErrorExtraccionClima(mensaje_error)

        datos_clima = respuesta.json()
        logger.info(f"Datos climáticos obtenidos exitosamente para {nombre_ubicacion}")

        return datos_clima

    except ErrorExtraccionClima:
        raise
    except requests.exceptions.RequestException as e:
        mensaje_error = f"Error de red al llamar API para {nombre_ubicacion}: {str(e)}"
        logger.error(mensaje_error)
        raise ErrorExtraccionClima(mensaje_error)
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
        'version_extractor': '2.0.0'  # Actualizado a v2 (API Key)
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
            'version': '2.0'
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
    1. Obtener API Key desde Secret Manager
    2. Consultar Weather API para cada ubicación configurada (GET con query params)
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

    cliente_publicador = None
    api_key = None

    try:
        # Validar configuración
        proyecto = ID_PROYECTO
        if not proyecto:
            raise ErrorConfiguracion(
                "ID_PROYECTO no configurado. "
                "Establecer variable de entorno GCP_PROJECT o GOOGLE_CLOUD_PROJECT"
            )

        # Obtener API Key desde Secret Manager
        logger.info("Obteniendo API Key desde Secret Manager...")
        api_key = obtener_api_key()

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
                # Llamar a Weather API con GET + API Key
                datos_clima = llamar_weather_api(
                    ubicacion['latitud'],
                    ubicacion['longitud'],
                    nombre_ubicacion,
                    api_key
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
        # Cerrar cliente si existe
        if cliente_publicador:
            try:
                # Pub/Sub client no necesita close explícito
                pass
            except Exception as e:
                logger.warning(f"Error al finalizar cliente: {str(e)}")
