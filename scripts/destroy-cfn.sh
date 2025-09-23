#!/usr/bin/env bash
set -euo pipefail

# Tear down EKS provisioned via CloudFormation templates in cloudformation/
# Deletes nodegroup stack first, then cluster stack.

# Load variables from an env file if present (default: env/cfn.env)
ENV_FILE=${ENV_FILE:-env/cfn.env}
if [[ -f "${ENV_FILE}" ]]; then
  echo "[info] Loading variables from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

AWS_REGION=${AWS_REGION:-us-east-1}
AWS_PROFILE=${AWS_PROFILE:-}
CLUSTER_STACK=${CLUSTER_STACK:-eks-cluster-stack}
NODEGROUP_STACK=${NODEGROUP_STACK:-eks-nodegroup-stack}

if ! command -v aws >/dev/null 2>&1; then
  echo "[error] aws CLI is required." >&2
  exit 1
fi

if [[ "${AWS_REGION}" != "us-east-1" && "${AWS_REGION}" != "us-west-2" ]]; then
  echo "[error] Learner Lab restricts regions to us-east-1 or us-west-2. Set AWS_REGION accordingly." >&2
  exit 1
fi

export AWS_REGION
if [[ -n "${AWS_PROFILE}" ]]; then
  export AWS_PROFILE
  echo "[info] Using AWS profile: ${AWS_PROFILE}"
fi

# Clean up Argo CD Applications and LoadBalancer Services to prevent orphaned AWS resources
if command -v kubectl >/dev/null 2>&1; then
  echo "[info] Cleaning up Argo CD Applications and LoadBalancer Services..."
  
  # Delete all Argo CD Applications (this will clean up their managed resources)
  if kubectl get namespace argocd >/dev/null 2>&1; then
    echo "[info] Deleting Argo CD Applications..."
    kubectl -n argocd delete applications --all --timeout=60s || echo "[warn] Failed to delete some Applications"
    
    # Wait a moment for Applications to clean up their resources
    sleep 10
  fi
  
  # Find and delete any remaining LoadBalancer Services across all namespaces
  echo "[info] Cleaning up LoadBalancer Services..."
  LB_SERVICES=$(kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  
  if [[ -n "$LB_SERVICES" ]]; then
    echo "[info] Found LoadBalancer Services to clean up:"
    echo "$LB_SERVICES"
    
    while IFS= read -r line; do
      if [[ -n "$line" ]]; then
        NS=$(echo "$line" | awk '{print $1}')
        SVC=$(echo "$line" | awk '{print $2}')
        echo "[info] Deleting LoadBalancer Service: $NS/$SVC"
        kubectl -n "$NS" delete svc "$SVC" --timeout=60s || echo "[warn] Failed to delete $NS/$SVC"
      fi
    done <<< "$LB_SERVICES"
    
    # Wait for AWS Load Balancers to be cleaned up
    echo "[info] Waiting 30s for AWS Load Balancers to be cleaned up..."
    sleep 30
  else
    echo "[info] No LoadBalancer Services found."
  fi
  
  # Clean up any remaining namespaces that might have finalizers
  echo "[info] Cleaning up application namespaces..."
  for ns in demo-12-factor-app sample-nginx; do
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
      echo "[info] Deleting namespace: $ns"
      kubectl delete namespace "$ns" --timeout=60s || echo "[warn] Failed to delete namespace $ns"
    fi
  done
else
  echo "[warn] kubectl not found. Skipping Kubernetes resource cleanup."
  echo "[warn] Manual cleanup may be needed for LoadBalancer Services and Applications."
fi

stack_exists() {
  local name=$1
  local status
  status=$(aws cloudformation describe-stacks --stack-name "$name" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
  [[ -n "$status" && "$status" != "None" && "$status" != "STACK_NOT_FOUND" ]]
}

# Delete nodegroup stack first
if stack_exists "${NODEGROUP_STACK}"; then
  echo "[info] Deleting stack: ${NODEGROUP_STACK} (nodegroup)"
  aws cloudformation delete-stack --stack-name "${NODEGROUP_STACK}"
  aws cloudformation wait stack-delete-complete --stack-name "${NODEGROUP_STACK}"
  echo "[done] Deleted ${NODEGROUP_STACK}"
else
  echo "[info] Stack ${NODEGROUP_STACK} not found. Skipping."
fi

# Delete cluster stack
if stack_exists "${CLUSTER_STACK}"; then
  echo "[info] Deleting stack: ${CLUSTER_STACK} (cluster)"
  aws cloudformation delete-stack --stack-name "${CLUSTER_STACK}"
  aws cloudformation wait stack-delete-complete --stack-name "${CLUSTER_STACK}"
  echo "[done] Deleted ${CLUSTER_STACK}"
else
  echo "[info] Stack ${CLUSTER_STACK} not found. Skipping."
fi

echo "[done] CloudFormation teardown complete."
