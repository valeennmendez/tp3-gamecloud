#!/bin/bash
# Elimina todos los recursos creados en MiniStack para esta practica.
set -e

awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

echo "=== Eliminando API Gateway ==="
API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)
if [ -n "$API_ID" ]; then
  awsl apigatewayv2 delete-api --api-id $API_ID
  echo "API $API_ID eliminada"
fi

echo "=== Eliminando funciones Lambda ==="
for fn in ranking recibir_puntaje procesar_puntaje; do
  awsl lambda delete-function --function-name $fn 2>/dev/null || echo "$fn no existia"
done

echo "=== Eliminando rol y politica IAM ==="
awsl iam delete-role-policy --role-name gamecloud-lambda-role --policy-name gamecloud-lambda-policy 2>/dev/null || true
awsl iam delete-role --role-name gamecloud-lambda-role 2>/dev/null || true

echo "=== Eliminando colas SQS ==="
PUNTAJES_URL=$(awsl sqs get-queue-url --queue-name puntajes --query QueueUrl --output text 2>/dev/null) || true
[ -n "$PUNTAJES_URL" ] && awsl sqs delete-queue --queue-url $PUNTAJES_URL
DLQ_URL=$(awsl sqs get-queue-url --queue-name puntajes-dlq --query QueueUrl --output text 2>/dev/null) || true
[ -n "$DLQ_URL" ] && awsl sqs delete-queue --queue-url $DLQ_URL

echo "=== Eliminando tabla DynamoDB ==="
awsl dynamodb delete-table --table-name Puntajes 2>/dev/null || echo "tabla no existia"

echo "=== Eliminando bucket S3 ==="
awsl s3 rb s3://gamecloud-web --force 2>/dev/null || echo "bucket no existia"

echo "Limpieza completa."
