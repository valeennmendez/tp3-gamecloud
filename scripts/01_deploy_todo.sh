#!/bin/bash
# Script de despliegue completo de la arquitectura GameCloud sobre MiniStack.
# Idempotente: puede re-ejecutarse sin romper nada si los recursos ya existen.
set -e

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awsl='aws --endpoint-url=http://localhost:4566' 2>/dev/null
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

cd "$(dirname "$0")/.."   # posicionarse en la raiz del proyecto (tp3-gamecloud/)

echo "=== 0. Verificando MiniStack ==="
awsl s3 ls > /dev/null && echo "MiniStack responde OK"

echo "=== 1. S3 + CloudFront ==="
awsl s3 mb s3://gamecloud-web 2>/dev/null || echo "bucket ya existe"
awsl s3 website s3://gamecloud-web/ --index-document index.html
awsl s3 cp web/index.html s3://gamecloud-web/index.html
awsl cloudfront create-distribution \
  --origin-domain-name gamecloud-web.s3.amazonaws.com \
  --default-root-object index.html > /tmp/cloudfront_out.json
echo "CloudFront distribution creada"

echo "=== 2. DynamoDB ==="
awsl dynamodb create-table \
  --table-name Puntajes \
  --attribute-definitions \
      AttributeName=juego,AttributeType=S \
      AttributeName=jugador,AttributeType=S \
  --key-schema \
      AttributeName=juego,KeyType=HASH \
      AttributeName=jugador,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST 2>/dev/null || echo "tabla ya existe"

echo "=== 3. SQS (DLQ + cola principal) ==="
awsl sqs create-queue --queue-name puntajes-dlq 2>/dev/null || echo "DLQ ya existe"
DLQ_URL=$(awsl sqs get-queue-url --queue-name puntajes-dlq --query QueueUrl --output text)
DLQ_ARN=$(awsl sqs get-queue-attributes --queue-url $DLQ_URL --attribute-names QueueArn --query Attributes.QueueArn --output text)

awsl sqs create-queue \
  --queue-name puntajes \
  --attributes "{
    \"VisibilityTimeout\": \"30\",
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"$DLQ_ARN\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
  }" 2>/dev/null || echo "cola puntajes ya existe"

PUNTAJES_URL=$(awsl sqs get-queue-url --queue-name puntajes --query QueueUrl --output text)
echo "PUNTAJES_URL=$PUNTAJES_URL"

echo "=== 4. IAM (rol + politica) ==="
awsl iam create-role \
  --role-name gamecloud-lambda-role \
  --assume-role-policy-document file://iam/trust-lambda.json 2>/dev/null || echo "rol ya existe"

awsl iam put-role-policy \
  --role-name gamecloud-lambda-role \
  --policy-name gamecloud-lambda-policy \
  --policy-document file://iam/politica-lambdas.json

echo "=== 5. Empaquetado y despliegue de las Lambdas ==="
cd lambdas
rm -f recibir_puntaje.zip procesar_puntaje.zip ranking.zip
zip -q recibir_puntaje.zip recibir_puntaje.py
zip -q procesar_puntaje.zip procesar_puntaje.py
zip -q ranking.zip ranking.py
cd ..

awsl lambda create-function \
  --function-name recibir_puntaje \
  --runtime python3.12 \
  --role arn:aws:iam::000000000000:role/gamecloud-lambda-role \
  --handler recibir_puntaje.handler \
  --zip-file fileb://lambdas/recibir_puntaje.zip \
  --environment "Variables={QUEUE_URL=$PUNTAJES_URL}" 2>/dev/null || \
awsl lambda update-function-code --function-name recibir_puntaje --zip-file fileb://lambdas/recibir_puntaje.zip

awsl lambda create-function \
  --function-name procesar_puntaje \
  --runtime python3.12 \
  --role arn:aws:iam::000000000000:role/gamecloud-lambda-role \
  --handler procesar_puntaje.handler \
  --zip-file fileb://lambdas/procesar_puntaje.zip \
  --environment "Variables={TABLE_NAME=Puntajes}" 2>/dev/null || \
awsl lambda update-function-code --function-name procesar_puntaje --zip-file fileb://lambdas/procesar_puntaje.zip

awsl lambda create-function \
  --function-name ranking \
  --runtime python3.12 \
  --role arn:aws:iam::000000000000:role/gamecloud-lambda-role \
  --handler ranking.handler \
  --zip-file fileb://lambdas/ranking.zip \
  --environment "Variables={TABLE_NAME=Puntajes}" 2>/dev/null || \
awsl lambda update-function-code --function-name ranking --zip-file fileb://lambdas/ranking.zip

echo "=== 6. Event source mapping (SQS -> procesar_puntaje) ==="
EXISTING_MAPPING=$(awsl lambda list-event-source-mappings --function-name procesar_puntaje --query "EventSourceMappings[0].UUID" --output text)
if [ "$EXISTING_MAPPING" == "None" ] || [ -z "$EXISTING_MAPPING" ]; then
  awsl lambda create-event-source-mapping \
    --function-name procesar_puntaje \
    --event-source-arn arn:aws:sqs:us-east-1:000000000000:puntajes \
    --batch-size 1
else
  echo "event source mapping ya existe: $EXISTING_MAPPING"
fi

echo "=== 7. API Gateway ==="
EXISTING_API=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)
if [ -z "$EXISTING_API" ]; then
  API_ID=$(awsl apigatewayv2 create-api \
    --name gamecloud-api \
    --protocol-type HTTP \
    --cors-configuration AllowOrigins="*",AllowMethods="GET,POST",AllowHeaders="*" \
    --query ApiId --output text)
else
  API_ID=$EXISTING_API
  echo "API ya existe: $API_ID"
fi
echo "API_ID=$API_ID"

INTEGRATION_RANKING=$(awsl apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:us-east-1:000000000000:function:ranking \
  --payload-format-version 2.0 \
  --query IntegrationId --output text)

awsl apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "GET /ranking" \
  --target integrations/$INTEGRATION_RANKING 2>/dev/null || echo "ruta GET /ranking ya existe"

INTEGRATION_SCORES=$(awsl apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:us-east-1:000000000000:function:recibir_puntaje \
  --payload-format-version 2.0 \
  --query IntegrationId --output text)

awsl apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "POST /scores" \
  --target integrations/$INTEGRATION_SCORES 2>/dev/null || echo "ruta POST /scores ya existe"

awsl lambda add-permission \
  --function-name ranking \
  --statement-id apigw-ranking \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:000000000000:$API_ID/*/*/ranking" 2>/dev/null || echo "permiso ranking ya existe"

awsl lambda add-permission \
  --function-name recibir_puntaje \
  --statement-id apigw-recibir \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:000000000000:$API_ID/*/*/scores" 2>/dev/null || echo "permiso recibir ya existe"

awsl apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy \
  --default-route-settings ThrottlingRateLimit=100,ThrottlingBurstLimit=200 2>/dev/null || echo "stage ya existe"

echo "=== 8. config.js ==="
cat > web/config.js << EOF
window.GAMECLOUD_API = "http://$API_ID.execute-api.localhost:4566";
EOF
awsl s3 cp web/config.js s3://gamecloud-web/config.js

echo ""
echo "========================================="
echo "DESPLIEGUE COMPLETO"
echo "API_ID=$API_ID"
echo "PUNTAJES_URL=$PUNTAJES_URL"
echo "Web: http://localhost:4566/gamecloud-web/index.html"
echo "========================================="
echo ""
echo "Para usar en tu sesion de shell actual, corre:"
echo "export API_ID=$API_ID"
echo "export PUNTAJES_URL=$PUNTAJES_URL"
