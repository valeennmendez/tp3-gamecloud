#!/bin/bash
# Ejecuta las pruebas de la Seccion 6 del TP de forma automatizada.
# Requiere que ya se haya corrido 01_deploy_todo.sh
set -e

awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)
PUNTAJES_URL=$(awsl sqs get-queue-url --queue-name puntajes --query QueueUrl --output text)
DLQ_URL=$(awsl sqs get-queue-url --queue-name puntajes-dlq --query QueueUrl --output text)
BASE_URL="http://$API_ID.execute-api.localhost:4566"

echo "=== Prueba 1: 5 puntajes validos ==="
for p in '{"jugador":"ana","juego":"doom","puntaje":9800}' \
         '{"jugador":"carlos","juego":"pacman","puntaje":5000}' \
         '{"jugador":"bruno","juego":"doom","puntaje":12000}' \
         '{"jugador":"maria","juego":"pacman","puntaje":7500}' \
         '{"jugador":"luis","juego":"doom","puntaje":15500}'; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE_URL/scores" \
    -H 'Content-Type: application/json' -d "$p"
done

echo "=== Prueba 2: juego inexistente (esperado 400) ==="
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE_URL/scores" \
  -H 'Content-Type: application/json' \
  -d '{"jugador":"test","juego":"tetris","puntaje":100}'

echo "=== Prueba 3: puntaje menor al mejor registrado (no debe cambiar el ranking) ==="
curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BASE_URL/scores" \
  -H 'Content-Type: application/json' \
  -d '{"jugador":"ana","juego":"doom","puntaje":3000}'
sleep 3
awsl dynamodb get-item --table-name Puntajes \
  --key '{"juego": {"S": "doom"}, "jugador": {"S": "ana"}}'

echo "=== Prueba 4: consultar ranking ==="
curl -s "$BASE_URL/ranking" | python3 -m json.tool
curl -s "$BASE_URL/ranking?juego=doom" | python3 -m json.tool

echo "=== Prueba 5: pico de 50 puntajes en paralelo (tandas de 10) ==="
contador=0
for i in $(seq 1 50); do
  curl -s -o /dev/null -X POST "$BASE_URL/scores" \
    -H 'Content-Type: application/json' \
    -d "{\"jugador\":\"jugador$i\",\"juego\":\"doom\",\"puntaje\":$((RANDOM % 20000))}" &
  contador=$((contador+1))
  if [ $((contador % 10)) -eq 0 ]; then wait; fi
done
wait
awsl sqs get-queue-attributes --queue-url $PUNTAJES_URL \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

echo "=== Prueba 6: mensaje invalido -> DLQ ==="
awsl sqs send-message --queue-url $PUNTAJES_URL --message-body "esto no es un JSON valido {{{"
echo "Esperando reintentos (visibility timeout x maxReceiveCount)..."
sleep 95
awsl sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names ApproximateNumberOfMessages

echo "=== Prueba 7: logs de procesar_puntaje ==="
awsl logs filter-log-events --log-group-name /aws/lambda/procesar_puntaje --filter-pattern "ERROR"

echo "Pruebas finalizadas."
