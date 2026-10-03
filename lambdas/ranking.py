import json
import os
import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]
table = dynamodb.Table(TABLE_NAME)

JUEGOS_VALIDOS = ["doom", "pacman"]


def _response(status_code, body_dict):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }


def _top10_de(juego):
    resp = table.query(
        KeyConditionExpression=Key("juego").eq(juego),
    )
    items = resp.get("Items", [])
    items.sort(key=lambda i: int(i["puntaje"]), reverse=True)
    return [
        {"jugador": i["jugador"], "puntaje": int(i["puntaje"])}
        for i in items[:10]
    ]


def handler(event, context):
    params = (event.get("queryStringParameters") or {})
    juego = params.get("juego")

    if juego:
        if juego not in JUEGOS_VALIDOS:
            return _response(400, {"error": "Juego invalido o inexistente"})
        return _response(200, {juego: _top10_de(juego)})

    # Sin parametro: devolver el top 10 de cada juego
    resultado = {j: _top10_de(j) for j in JUEGOS_VALIDOS}
    return _response(200, resultado)
