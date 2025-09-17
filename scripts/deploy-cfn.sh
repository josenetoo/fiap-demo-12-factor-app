#!/usr/bin/env bash
set -euo pipefail

# Provision EKS using CloudFormation templates in cloudformation/ and install Argo CD
# Designed for AWS Learner Lab constraints: regions us-east-1/us-west-2, reuse existing IAM roles, VPC default.

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
QUICK=${QUICK:-0}
CLUSTER_STACK=${CLUSTER_STACK:-eks-cluster-stack}
NODEGROUP_STACK=${NODEGROUP_STACK:-eks-nodegroup-stack}
CLUSTER_NAME=${CLUSTER_NAME:-demo-12-factor-eks}
K8S_VERSION=${K8S_VERSION:-}

# Required: existing IAM role ARNs
CLUSTER_ROLE_ARN=${CLUSTER_ROLE_ARN:-}
NODE_ROLE_ARN=${NODE_ROLE_ARN:-}

# Optional networking overrides; if blank we'll auto-detect default VPC subnets and default SG
SUBNET_IDS=${SUBNET_IDS:-}
SECURITY_GROUP_IDS=${SECURITY_GROUP_IDS:-}

# Optional nodegroup params
INSTANCE_TYPES=${INSTANCE_TYPES:-t3.micro}
DESIRED_SIZE=${DESIRED_SIZE:-1}
MIN_SIZE=${MIN_SIZE:-1}
MAX_SIZE=${MAX_SIZE:-1}
DISK_SIZE=${DISK_SIZE:-20}
CAPACITY_TYPE=${CAPACITY_TYPE:-ON_DEMAND}
NODEGROUP_NAME=${NODEGROUP_NAME:-ng-1}

if ! command -v aws >/dev/null 2>&1; then
  echo "[error] aws CLI is required." >&2
  exit 1
fi
if ! command -v kubectl >/dev/null 2>&1; then
  echo "[error] kubectl is required." >&2
  exit 1
fi

if [[ "${AWS_REGION}" != "us-east-1" && "${AWS_REGION}" != "us-west-2" ]]; then
  echo "[error] Learner Lab restricts regions to us-east-1 or us-west-2. Set AWS_REGION accordingly." >&2
  exit 1
fi

if [[ -z "${CLUSTER_ROLE_ARN}" || -z "${NODE_ROLE_ARN}" ]]; then
  cat >&2 <<EOF
[error] You must set CLUSTER_ROLE_ARN and NODE_ROLE_ARN environment variables to existing IAM role ARNs.
Example:
  export CLUSTER_ROLE_ARN=arn:aws:iam::ACCOUNT_ID:role/LabEksClusterRole
  export NODE_ROLE_ARN=arn:aws:iam::ACCOUNT_ID:role/LabEksNodeRole
EOF
  exit 1
fi

export AWS_REGION
if [[ -n "${AWS_PROFILE}" ]]; then
  export AWS_PROFILE
  echo "[info] Using AWS profile: ${AWS_PROFILE}"
fi

# QUICK mode: if role ARNs are not provided, try to use LabRole automatically
if [[ "${QUICK}" == "1" ]]; then
  echo "[info] QUICK mode enabled: attempting to auto-fill role ARNs as LabRole"
fi

if [[ -z "${CLUSTER_ROLE_ARN}" || -z "${NODE_ROLE_ARN}" ]]; then
  if [[ "${QUICK}" == "1" || -z "${CLUSTER_ROLE_ARN}" || -z "${NODE_ROLE_ARN}" ]]; then
    echo "[info] Resolving current AWS account ID via STS..."
    ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)
    if [[ -n "${ACCOUNT_ID}" && "${ACCOUNT_ID}" != "None" ]]; then
      : "${CLUSTER_ROLE_ARN:="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"}"
      : "${NODE_ROLE_ARN:="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"}"
      echo "[info] Using inferred CLUSTER_ROLE_ARN=${CLUSTER_ROLE_ARN}"
      echo "[info] Using inferred NODE_ROLE_ARN=${NODE_ROLE_ARN}"
    else
      echo "[warn] Could not resolve ACCOUNT_ID. Please set CLUSTER_ROLE_ARN and NODE_ROLE_ARN explicitly."
    fi
  fi
fi

# Resolve networking if not provided
if [[ -z "${SUBNET_IDS}" || -z "${SECURITY_GROUP_IDS}" ]]; then
  echo "[info] Discovering default VPC and networking in ${AWS_REGION}..."
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
    echo "[error] No default VPC found in ${AWS_REGION}. Provide SUBNET_IDS and SECURITY_GROUP_IDS explicitly." >&2
    exit 1
  fi
  # Get subnets with AZ and filter out unsupported AZs (e.g., us-east-1e for EKS control plane)
  MAP_OUTPUT=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" \
    --query 'Subnets[][SubnetId,AvailabilityZone]' --output text)
  if [[ -z "${MAP_OUTPUT}" ]]; then
    echo "[error] Could not discover subnets for VPC ${VPC_ID}." >&2
    exit 1
  fi

  # Build a comma-separated list of up to 3 subnets across distinct allowed AZs (a,b,c,d,f)
  SUBNET_IDS=""
  SEEN_AZS=""
  COUNT=0
  while read -r ID AZ; do
    [[ -z "$ID" || -z "$AZ" ]] && continue
    SUFFIX=${AZ: -1}
    case "$SUFFIX" in
      e|E)
        # Skip AZs like us-east-1e which EKS control plane may not support
        continue
        ;;
    esac
    if [[ " ${SEEN_AZS} " == *" ${AZ} "* ]]; then
      continue
    fi
    if [[ -z "$SUBNET_IDS" ]]; then
      SUBNET_IDS="$ID"
    else
      SUBNET_IDS+=",$ID"
    fi
    SEEN_AZS+=" ${AZ}"
    COUNT=$((COUNT+1))
    # Pick up to 3 AZs for better HA; EKS requires at least 2
    if [[ $COUNT -ge 3 ]]; then
      break
    fi
  done <<< "$MAP_OUTPUT"

  # Ensure we have at least 2 distinct AZs selected
  if [[ $COUNT -lt 2 ]]; then
    echo "[error] Discovered fewer than 2 supported AZs in default VPC. Provide SUBNET_IDS explicitly." >&2
    echo "[debug] Raw subnets:"
    echo "$MAP_OUTPUT" >&2
    exit 1
  fi
  # Default security group of the VPC
  SECURITY_GROUP_IDS=$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values="${VPC_ID}" Name=group-name,Values=default \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [[ -z "${SECURITY_GROUP_IDS}" || "${SECURITY_GROUP_IDS}" == "None" ]]; then
    echo "[error] Could not discover default security group for VPC ${VPC_ID}." >&2
    exit 1
  fi
  echo "[info] Using SubnetIds: ${SUBNET_IDS}"
  echo "[info] Using SecurityGroupIds: ${SECURITY_GROUP_IDS}"
fi

echo "[info] Checking existing cluster stack state: ${CLUSTER_STACK}"
EXISTING_STATUS=$(aws cloudformation describe-stacks --stack-name "${CLUSTER_STACK}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
if [[ "${EXISTING_STATUS}" == ROLLBACK_COMPLETE || "${EXISTING_STATUS}" == ROLLBACK_FAILED ]]; then
  echo "[warn] Stack ${CLUSTER_STACK} is in ${EXISTING_STATUS}. Deleting it before re-deploying..."
  aws cloudformation delete-stack --stack-name "${CLUSTER_STACK}"
  aws cloudformation wait stack-delete-complete --stack-name "${CLUSTER_STACK}"
  echo "[info] Previous stack ${CLUSTER_STACK} deleted. Proceeding with fresh deploy."
elif [[ -n "${EXISTING_STATUS}" && "${EXISTING_STATUS}" != "None" && "${EXISTING_STATUS}" != "STACK_NOT_FOUND" ]]; then
  echo "[info] Existing stack status: ${EXISTING_STATUS}"
fi

echo "[info] Deploying CloudFormation stack: ${CLUSTER_STACK} (EKS Cluster)"
if [[ -n "${K8S_VERSION}" ]]; then
  aws cloudformation deploy \
    --stack-name "${CLUSTER_STACK}" \
    --template-file cloudformation/eks-cluster.yaml \
    --parameter-overrides \
      ClusterName="${CLUSTER_NAME}" \
      ClusterRoleArn="${CLUSTER_ROLE_ARN}" \
      SubnetIds="${SUBNET_IDS}" \
      SecurityGroupIds="${SECURITY_GROUP_IDS}" \
      KubernetesVersion="${K8S_VERSION}" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset
else
  aws cloudformation deploy \
    --stack-name "${CLUSTER_STACK}" \
    --template-file cloudformation/eks-cluster.yaml \
    --parameter-overrides \
      ClusterName="${CLUSTER_NAME}" \
      ClusterRoleArn="${CLUSTER_ROLE_ARN}" \
      SubnetIds="${SUBNET_IDS}" \
      SecurityGroupIds="${SECURITY_GROUP_IDS}" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset
fi

# Wait until the cluster is active, then update kubeconfig
echo "[info] Waiting for EKS cluster to be ACTIVE..."
aws eks wait cluster-active --name "${CLUSTER_NAME}" --region "${AWS_REGION}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

echo "[info] Deploying CloudFormation stack: ${NODEGROUP_STACK} (EKS Nodegroup)"
# Handle previous rollback on nodegroup stack
NG_STATUS=$(aws cloudformation describe-stacks --stack-name "${NODEGROUP_STACK}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
if [[ "${NG_STATUS}" == ROLLBACK_COMPLETE || "${NG_STATUS}" == ROLLBACK_FAILED ]]; then
  echo "[warn] Stack ${NODEGROUP_STACK} is in ${NG_STATUS}. Deleting it before re-deploying..."
  aws cloudformation delete-stack --stack-name "${NODEGROUP_STACK}"
  aws cloudformation wait stack-delete-complete --stack-name "${NODEGROUP_STACK}"
  echo "[info] Previous stack ${NODEGROUP_STACK} deleted. Proceeding with fresh deploy."
elif [[ -n "${NG_STATUS}" && "${NG_STATUS}" != "None" && "${NG_STATUS}" != "STACK_NOT_FOUND" ]]; then
  echo "[info] Existing nodegroup stack status: ${NG_STATUS}"
fi
aws cloudformation deploy \
  --stack-name "${NODEGROUP_STACK}" \
  --template-file cloudformation/eks-nodegroup.yaml \
  --parameter-overrides \
    ClusterName="${CLUSTER_NAME}" \
    NodegroupName="${NODEGROUP_NAME}" \
    NodeRoleArn="${NODE_ROLE_ARN}" \
    SubnetIds="${SUBNET_IDS}" \
    InstanceTypes="${INSTANCE_TYPES}" \
    DesiredSize="${DESIRED_SIZE}" \
    MinSize="${MIN_SIZE}" \
    MaxSize="${MAX_SIZE}" \
    DiskSize="${DISK_SIZE}" \
    CapacityType="${CAPACITY_TYPE}" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# Install Argo CD
echo "[info] Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Optionally set Argo CD admin password if ARGOCD_ADMIN_PASSWORD is provided
if [[ -n "${ARGOCD_ADMIN_PASSWORD:-}" ]]; then
  echo "[info] ARGOCD_ADMIN_PASSWORD provided: attempting to set Argo CD admin password"
  # Wait for argocd-server to be ready to accept connections
  kubectl -n argocd rollout status deploy/argocd-server --timeout=180s || true

  if command -v argocd >/dev/null 2>&1; then
    echo "[info] Using argocd CLI to update admin password"
    # Port-forward server in background
    kubectl -n argocd port-forward svc/argocd-server 8080:80 >/dev/null 2>&1 &
    PF_PID=$!
    # Ensure we clean up port-forward on exit
    cleanup_pf() { kill "$PF_PID" >/dev/null 2>&1 || true; }
    trap cleanup_pf EXIT
    # Give it a moment to bind
    sleep 4

    INITIAL_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d || true)
    if [[ -z "$INITIAL_PW" ]]; then
      echo "[warn] Could not retrieve initial admin password; continuing but argocd CLI login may fail"
    fi

    # Try grpc-web first (works via port-forward to HTTP 80)
    if ! argocd login localhost:8080 --username admin --password "$INITIAL_PW" --insecure --grpc-web >/dev/null 2>&1; then
      # Fallback without grpc-web
      argocd login localhost:8080 --username admin --password "$INITIAL_PW" --insecure >/dev/null 2>&1 || true
    fi

    if argocd account update-password --account admin --current-password "$INITIAL_PW" --new-password "$ARGOCD_ADMIN_PASSWORD" >/dev/null 2>&1; then
      echo "[done] Argo CD admin password updated via argocd CLI"
    else
      echo "[warn] argocd CLI password update failed. You may need to retry after Argo CD is fully ready."
    fi

    # Cleanup port-forward
    cleanup_pf
    trap - EXIT
  else
    echo "[warn] argocd CLI not found. Attempting to patch secret directly (requires htpasswd)."
    if command -v htpasswd >/dev/null 2>&1; then
      # Generate bcrypt hash with cost 10 (compatible with Argo CD)
      BCRYPT=$(htpasswd -nbBC 10 admin "$ARGOCD_ADMIN_PASSWORD" | cut -d: -f2)
      NOW=$(date -u +%FT%TZ)
      kubectl -n argocd patch secret argocd-secret \
        --type merge \
        -p "{\"stringData\": {\"admin.password\": \"$BCRYPT\", \"admin.passwordMtime\": \"$NOW\"}}" || echo "[warn] Failed to patch argocd-secret"
      echo "[done] Attempted to update Argo CD admin password via secret patch"
    else
      cat <<EOF
[error] Neither argocd CLI nor htpasswd found.
Install argocd CLI (https://argo-cd.readthedocs.io/) or htpasswd (apache2-utils) and rerun with ARGOCD_ADMIN_PASSWORD set.
EOF
    fi
  fi
fi

# Apply sample app if present (for students' quick validation)
if [[ -f argocd/application-sample.yaml ]]; then
  echo "[info] Applying Argo CD Sample Application (argocd/application-sample.yaml)"
  kubectl apply -f argocd/application-sample.yaml
  echo "[hint] Sample app 'sample-nginx' will deploy to namespace 'sample-nginx'."
fi

echo "[done] EKS provisioned via CloudFormation and Argo CD installed."
if [[ -f argocd/application-sample.yaml ]]; then
  echo "If you applied the sample app, access it via:"
  echo "  kubectl -n sample-nginx port-forward svc/sample-nginx-nginx 8080:80"
  echo "  curl http://localhost:8080/"
fi
echo "To deploy your own app, create an Argo CD Application manifest and apply it:"
echo "  kubectl apply -f argocd/your-app.yaml"
