import json
import os
import boto3

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["QUEUE_URL"]

# Lista cerrada de juegos válidos para esta plataforma
JUEGOS_VALIDOS = {"doom", "pacman"}


def _response(status_code, body_dict):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, TypeError):
        return _response(400, {"error": "Body invalido, se esperaba JSON"})

    jugador = body.get("jugador")
    juego = body.get("juego")
    puntaje = body.get("puntaje")

    # Validaciones de tipo y contenido
    if not isinstance(jugador, str) or not jugador.strip():
        return _response(400, {"error": "Campo 'jugador' invalido"})

    if not isinstance(juego, str) or juego not in JUEGOS_VALIDOS:
        return _response(400, {"error": "Campo 'juego' invalido o inexistente"})

    if not isinstance(puntaje, int) or isinstance(puntaje, bool) or puntaje < 0:
        return _response(400, {"error": "Campo 'puntaje' debe ser un entero no negativo"})

    mensaje = {
        "jugador": jugador.strip(),
        "juego": juego,
        "puntaje": puntaje,
    }

    # Solo encola: no escribe en la base, eso lo hace procesar_puntaje
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(mensaje),
    )

    return _response(202, {"status": "Accepted", "mensaje": mensaje})
