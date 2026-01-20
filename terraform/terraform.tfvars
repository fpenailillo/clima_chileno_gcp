# Variables de Terraform para el proyecto clima-chileno
# Este archivo contiene la configuración real del proyecto

# ID del proyecto de Google Cloud Platform
id_proyecto = "clima-chileno"

# Región de GCP donde desplegar los recursos
# Usando us-central1 por defecto (Iowa, USA)
# Alternativas: southamerica-east1 (São Paulo, Brazil - más cercano a Chile)
region = "us-central1"

# Zona horaria para Cloud Scheduler
# America/Santiago corresponde a la zona horaria de Chile
zona_horaria = "America/Santiago"

# Frecuencia de extracción en formato cron
# "0 * * * *" = Cada hora en punto
# Puedes ajustar según necesidades:
#   "*/30 * * * *" = Cada 30 minutos
#   "0 */2 * * *" = Cada 2 horas
#   "0 6,12,18 * * *" = A las 6am, 12pm y 6pm
frecuencia_extraccion = "0 * * * *"
