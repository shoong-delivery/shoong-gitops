#!/bin/bash
# terraform apply 후 실행: ALB Target Group과 Istio IngressGateway 파드를 연결
set -e

REGION=${AWS_REGION:-us-east-1}

TG_ARN=$(aws ssm get-parameter \
  --name "/shoong/dev/alb-target-group-arn" \
  --query "Parameter.Value" \
  --output text \
  --region "$REGION")

echo "1) dev 네임스페이스에 istio sidecar injection 라벨 추가"
kubectl label namespace dev istio-injection=enabled --overwrite

echo "2) TargetGroupBinding 적용 (TG ARN: $TG_ARN)"
kubectl apply -f - <<EOF
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  serviceRef:
    name: istio-ingressgateway
    port: 80
  targetGroupARN: ${TG_ARN}
  targetType: ip
EOF

echo "3) 기존 파드 재시작 (sidecar 주입 적용)"
kubectl rollout restart deployment -n dev

echo "Done. ALB → Istio IngressGateway 연결 완료"
