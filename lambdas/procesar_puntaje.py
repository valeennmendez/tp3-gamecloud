import json
import os
import boto3

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]
table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    """
    Disparada por el event source mapping de la cola 'puntajes'.
    Si un mensaje individual lanza una excepción (por ejemplo, JSON invalido),
    SQS lo vuelve a poner en la cola luego del visibility timeout, y tras
    3 intentos fallidos (maxReceiveCount) lo redirige automaticamente a la DLQ.
    """
    for record in event.get("Records", []):
        body_raw = record.get("body", "")

        # Si el contenido no es JSON valido, dejamos que la excepcion
        # se propague para que SQS reintente y eventualmente mande a la DLQ.
        mensaje = json.loads(body_raw)

        jugador = mensaje["jugador"]
        juego = mensaje["juego"]
        puntaje_nuevo = mensaje["puntaje"]

        item_actual = table.get_item(Key={"juego": juego, "jugador": jugador}).get("Item")

        mejor_puntaje_actual = item_actual["puntaje"] if item_actual else None

        if mejor_puntaje_actual is None or puntaje_nuevo > mejor_puntaje_actual:
            table.put_item(Item={
                "juego": juego,
                "jugador": jugador,
                "puntaje": puntaje_nuevo,
            })
            print(f"Nuevo mejor puntaje guardado: {juego}/{jugador} = {puntaje_nuevo}")
        else:
            print(
                f"Puntaje descartado (no supera el mejor registrado): "
                f"{juego}/{jugador} = {puntaje_nuevo} <= {mejor_puntaje_actual}"
            )

    return {"statusCode": 200}
