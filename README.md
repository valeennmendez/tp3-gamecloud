# GameCloud - Ranking Online (TP3 - Aplicaciones en la Nube)

Arquitectura serverless para publicar un ranking online de puntajes de los juegos Doom y
Pac-Man, desplegada sobre AWS (emulado localmente con **MiniStack**).

## Arquitectura

```
Jugador --> CloudFront --> S3 (web)
   |
   | GET /ranking --> API Gateway --> Lambda ranking -------\
   | POST /scores --> API Gateway --> Lambda recibir_puntaje  --> DynamoDB Puntajes
                                            |                          ^
                                            v                          |
                                       SQS puntajes ---3x--> DLQ   Lambda procesar_puntaje
                                            |______________________________^
```

- **S3 + CloudFront**: sirven el frontend estático (`web/index.html`).
- **API Gateway (HTTP API)**: expone `GET /ranking` y `POST /scores`.
- **Lambda `recibir_puntaje`**: valida el puntaje recibido y lo encola en SQS (no escribe en la base).
- **SQS `puntajes` + DLQ `puntajes-dlq`**: desacopla la recepción del procesamiento. Luego de 3
  intentos fallidos, un mensaje se mueve automáticamente a la dead-letter queue.
- **Lambda `procesar_puntaje`**: consume la cola y guarda en DynamoDB solo si el puntaje supera
  el mejor registrado de ese jugador en ese juego (operación idempotente).
- **Lambda `ranking`**: consulta DynamoDB y devuelve el top 10 por juego.
- **DynamoDB `Puntajes`**: clave de partición `juego` (HASH) + clave de ordenamiento `jugador`
  (RANGE), modo `PAY_PER_REQUEST`.
- **IAM**: rol `gamecloud-lambda-role` con una política de mínimo privilegio (solo los permisos
  necesarios sobre la tabla, la cola y los logs).

## Requisitos

- Docker y Docker Compose
- AWS CLI v2
- bash, curl, zip, unzip
- (Windows: se recomienda WSL2)

## Cómo reproducir la práctica

### 1. Levantar MiniStack

```bash
docker compose up -d
```

(equivalente a `docker run -d --name ministack -p 4566:4566 -v /var/run/docker.sock:/var/run/docker.sock ministackorg/ministack`)

### 2. Configurar credenciales ficticias

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awsl='aws --endpoint-url=http://localhost:4566'

awsl s3 ls   # debe responder sin error (lista vacía)
```

### 3. Desplegar toda la arquitectura

```bash
bash scripts/01_deploy_todo.sh
```

Este script es **idempotente**: crea el bucket S3, la distribución de CloudFront, la tabla
DynamoDB, las colas SQS, el rol y la política IAM, empaqueta y despliega las tres funciones
Lambda, conecta el event source mapping, crea la API Gateway completa (rutas, integraciones,
permisos, stage), y genera/sube el `config.js` con la URL real de la API.

Al finalizar, exportá las variables que te indica el script para poder usarlas en pruebas
manuales:

```bash
export API_ID=<el-id-que-devuelva-el-script>
export PUNTAJES_URL=<la-url-que-devuelva-el-script>
```

### 4. Probar la aplicación

Acceder desde el navegador a:

```
http://localhost:4566/gamecloud-web/index.html
```

O probar la API directamente:

```bash
curl -X POST http://$API_ID.execute-api.localhost:4566/scores \
  -H 'Content-Type: application/json' \
  -d '{"jugador":"ana","juego":"doom","puntaje":9800}'

curl http://$API_ID.execute-api.localhost:4566/ranking
curl "http://$API_ID.execute-api.localhost:4566/ranking?juego=doom"
```

### 5. Limpieza

Para detener y eliminar el entorno:

```bash
docker compose down
```

**Nota importante**: MiniStack mantiene el estado de los recursos AWS únicamente **en memoria**
dentro del contenedor. Al detener o reiniciar el contenedor, se pierde todo lo desplegado (tablas,
colas, funciones, API). Para recrear el entorno completo luego de un reinicio, simplemente volvé
a correr `docker compose up -d` seguido de `bash scripts/01_deploy_todo.sh`.

## Estructura del repositorio

```
tp3-gamecloud/
├── README.md
├── docker-compose.yml
├── iam/
│   ├── trust-lambda.json        # Trust policy: permite a Lambda asumir el rol
│   └── politica-lambdas.json    # Política de minimo privilegio (DynamoDB, SQS, Logs)
├── lambdas/
│   ├── ranking.py                # GET /ranking - top 10 por juego
│   ├── recibir_puntaje.py        # POST /scores - valida y encola en SQS
│   └── procesar_puntaje.py       # Consumidor de SQS - persiste en DynamoDB si corresponde
├── scripts/
│   └── 01_deploy_todo.sh         # Despliegue completo e idempotente de toda la arquitectura
└── web/
    ├── index.html                 # Frontend estático del ranking
    └── config.js                  # Generado por el script, apunta a la URL de la API
```

## Autor

Trabajo Práctico N°3 - Administración Avanzada de Redes y Servidores - UNNOBA
