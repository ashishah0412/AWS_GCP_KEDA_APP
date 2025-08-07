#!/bin/bash
set -eo pipefail

# --- Configuration Variables ---
export EKS_CLUSTER_NAME="hello-keda-cluster"
export AWS_REGION="us-east-1" # <--- REPLACE WITH YOUR AWS_REGION
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

export ECR_REPO_NAME="hello-keda-app"
export IMAGE_TAG="latest"

export APP_NAMESPACE="hello-keda-app"
export KEDA_NAMESPACE="keda"
export EXTERNAL_SECRETS_NAMESPACE="external-secrets"

# --- GCP Configuration ---
# <--- REPLACE WITH YOUR ACTUAL GCP PROJECT ID
export GCP_PROJECT_ID="your-gcp-project-id"

# --- Define Your Topics and Subscriptions ---
# Key: TOPIC_IDENTIFIER (used in K8s resource names/labels)
# Value: PUBSUB_SUBSCRIPTION_ID (actual GCP Pub/Sub Subscription ID)
# declare -A TOPIC_CONFIGS=(
#   ["alpha"]="my-pubsub-subscription-alpha"
#   ["beta"]="my-pubsub-subscription-beta"
#   ["gamma"]="my-pubsub-subscription-gamma"
# )

# declare -A TOPIC_CONFIGS
# TOPIC_CONFIGS["alpha"]="my-pubsub-subscription-alpha"
# TOPIC_CONFIGS["beta"]="my-pubsub-subscription-beta"
# TOPIC_CONFIGS["gamma"]="my-pubsub-subscription-gamma"

TOPIC_IDS=("alpha" "beta" "gamma")
PUBSUB_SUBSCRIPTION_IDS=("my-pubsub-subscription-alpha" "my-pubsub-subscription-beta" "my-pubsub-subscription-gamma")

# K8s Manifests paths (Templates)
export APP_DEPLOYMENT_TEMPLATE="k8s/deployment-template.yml"
export APP_SERVICE_TEMPLATE="k8s/service-template.yml"
export KEDA_SCALER_TEMPLATE="k8s/gcp-keda-scaler-template.yml"

# K8s Manifests paths (Shared)
export EXTERNAL_SECRET_CONFIG_FILE="k8s/external-secret.yml"
export IAM_ROLE_SA_FILE="k8s/iam-role-service-account.yml"
export KEDA_TRIGGER_AUTH_FILE="k8s/trigger-authentication.yml"
export APP_NAMESPACE_FILE="k8s/namespace.yml"

# Versions for operators
export KEDA_VERSION="2.17.2" # Verify current stable KEDA version!
#export EXTERNAL_SECRETS_HELM_CHART_VERSION="0.10.2" # Verify current stable External Secrets Helm chart version!
export EXTERNAL_SECRETS_HELM_CHART_VERSION="0.19.0" # Verify current stable External Secrets Helm chart version!


# --- Helper Function for Error Handling ---
handle_error() {
  echo "ERROR: $1"
  exit 1
}

# --- 0. Pre-requisite Check & Placeholders ---
echo "--- 0. Pre-requisite Check & Placeholders ---"
echo "--- IMPORTANT: Ensure you have replaced ALL placeholders in the .yml files and in this script! ---"
echo "--- GCP_PROJECT_ID in this script and .yml files must be correct. ---"
echo "--- AWS_REGION in this script and .yml files must be correct. ---"
echo "--- IAM Role ARNs in k8s/iam-role-service-account.yml must be correct. ---"
echo "--- AWS Account ID will be fetched automatically. ---"
sleep 5 # Give user time to read

# --- 1. AWS CLI & Kubectl Configuration ---
echo "--- 1. AWS CLI & Kubectl Configuration ---"
echo "--- Configuring AWS CLI and Kubectl ---"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}" || handle_error "Failed to update kubeconfig. Ensure EKS cluster exists and you have permissions."
echo "AWS CLI and Kubectl configured."

# --- 2. Build and Push Docker Image ---
echo "--- 2. Building and Pushing Docker Image to ECR ---"
echo "--- Building and pushing Docker image ---"
docker build -t "${ECR_REPO_NAME}" . || handle_error "Docker build failed"
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}".dkr.ecr."${AWS_REGION}".amazonaws.com || handle_error "ECR login failed"

# Check if ECR repo exists, create if not
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${AWS_REGION}" &>/dev/null || \
  aws ecr create-repository --repository-name "${ECR_REPO_NAME}" --region "${AWS_REGION}" || handle_error "Failed to create ECR repository for app"

docker tag "${ECR_REPO_NAME}":"${IMAGE_TAG}" "${AWS_ACCOUNT_ID}".dkr.ecr."${AWS_REGION}".amazonaws.com/"${ECR_REPO_NAME}":"${IMAGE_TAG}" || handle_error "Docker tag failed"
docker push "${AWS_ACCOUNT_ID}".dkr.ecr."${AWS_REGION}".amazonaws.com/"${ECR_REPO_NAME}":"${IMAGE_TAG}" || handle_error "Docker push failed"
echo "Application Docker image pushed to ECR."

# --- 3. Deploy KEDA Core Components ---
echo "--- 3. Deploying KEDA Core Components ---"
echo "--- Deploying KEDA Core Components ---"
KEDA_CRDS_URL="https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}-crds.yaml"
KEDA_CORE_URL="https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}-core.yaml"
KEDA_CORE_FILE="keda-${KEDA_VERSION}-core.yaml" # Local filename

kubectl create namespace "${KEDA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - || handle_error "Failed to create KEDA namespace"

echo "Applying KEDA CRDs..."
kubectl apply --server-side -f "${KEDA_CRDS_URL}" || handle_error "Failed to apply KEDA CRDs"

echo "Downloading KEDA core manifest..."
curl -LO "${KEDA_CORE_URL}" || handle_error "Failed to download KEDA core manifest"

echo "Injecting Fargate toleration into KEDA operator deployments using yq..."
yq e '
  . as $doc |
  (select(.kind == "Deployment" and .metadata.name == "keda-operator") | .spec.template.spec.tolerations) = [{"key": "eks.amazonaws.com/compute-type", "operator": "Equal", "value": "fargate", "effect": "NoSchedule"}] |
  (select(.kind == "Deployment" and .metadata.name == "keda-metrics-apiserver") | .spec.template.spec.tolerations) = [{"key": "eks.amazonaws.com/compute-type", "operator": "Equal", "value": "fargate", "effect": "NoSchedule"}]
' -i "${KEDA_CORE_FILE}" || handle_error "Failed to inject KEDA tolerations with yq"


echo "Applying KEDA core manifest with tolerations..."
kubectl apply --server-side -f "${KEDA_CORE_FILE}" || handle_error "Failed to apply KEDA core manifest"
rm "${KEDA_CORE_FILE}" # Clean up local file

echo "Waiting for KEDA operators to be ready (timeout 5 minutes)..."
kubectl wait --for=condition=Available deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=300s || handle_error "KEDA operator not ready"
kubectl wait --for=condition=Available deployment/keda-metrics-apiserver -n "${KEDA_NAMESPACE}" --timeout=300s || handle_error "KEDA metrics-apiserver not ready"
echo "KEDA operators are ready."

# --- 4. Deploy External Secrets Operator ---

echo "--- Deploying External Secrets Operator ---"
kubectl create namespace "${EXTERNAL_SECRETS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - || handle_error "Failed to create External Secrets namespace"

helm repo add external-secrets https://charts.external-secrets.io || handle_error "Failed to add external-secrets helm repo"
helm repo update || handle_error "Failed to update helm repos"


EXTERNAL_SECRETS_CONTROLLER_IMAGE="ghcr.io/external-secrets/external-secrets:v${EXTERNAL_SECRETS_HELM_CHART_VERSION}"
EXTERNAL_SECRETS_WEBHOOK_IMAGE="ghcr.io/external-secrets/external-secrets-webhook:v${EXTERNAL_SECRETS_HELM_CHART_VERSION}"

# Check if ECR repo for external-secrets exists, create if not
aws ecr describe-repositories --repository-names external-secrets/external-secrets --region "${AWS_REGION}" &>/dev/null || \
  aws ecr create-repository --repository-name external-secrets/external-secrets --region "${AWS_REGION}" || handle_error "Failed to create ECR repo for external-secrets"
aws ecr describe-repositories --repository-names external-secrets/external-secrets-webhook --region "${AWS_REGION}" &>/dev/null || \
  aws ecr create-repository --repository-name external-secrets/external-secrets-webhook --region "${AWS_REGION}" || handle_error "Failed to create ECR repo for external-secrets-webhook"

# Deploy External Secrets from your private ECR mirror
helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace "${EXTERNAL_SECRETS_NAMESPACE}" \
    --create-namespace \
    --set installCRDs=true \
    --set image.tag="v${EXTERNAL_SECRETS_HELM_CHART_VERSION}" \
    --set webhook.image.tag="v${EXTERNAL_SECRETS_HELM_CHART_VERSION}" \
    --set controller.tolerations[0].key="eks.amazonaws.com/compute-type" \
    --set controller.tolerations[0].operator="Equal" \
    --set controller.tolerations[0].value="fargate" \
    --set controller.tolerations[0].effect="NoSchedule" \
    --set webhook.tolerations[0].key="eks.amazonaws.com/compute-type" \
    --set webhook.tolerations[0].operator="Equal" \
    --set webhook.tolerations[0].value="fargate" \
    --set webhook.tolerations[0].effect="NoSchedule" \
    --set webhook.certManager.enabled=false \
    --set webhook.recreate=true \
    --set webhook.generateSelfSignedCert=true \
    --wait || handle_error "Failed to install External Secrets operator"
echo "External Secrets Operator deployed."

# ADD THIS LINE HERE
echo "Waiting for External Secrets CRDs to be ready..."
sleep 30

# --- 5. Create Application Namespace ---
echo "--- 5. Creating Application Namespace ---"
echo "--- Creating Application Namespace ---"
kubectl create namespace "${APP_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - || handle_error "Failed to create application namespace"
echo "Application namespace created."

# --- 6. Deploy IAM Role for Service Accounts (IRSA) ---
echo "--- 6. Deploying IAM Role Service Accounts (IRSA) ---"
# IMPORTANT: Ensure you have already run `eksctl create iamserviceaccount` for these SAs
# as described in the README, linking them to their respective IAM roles.
echo "--- Deploying IAM Role Service Accounts (verify IRSA linking in README) ---"
kubectl apply -f "${IAM_ROLE_SA_FILE}" || handle_error "Failed to apply IAM Role Service Accounts"
echo "IAM Role Service Accounts deployed. Ensure they are correctly linked to AWS IAM Roles via eksctl."

# Check for and wait for the CRDs to be available. This is a robust alternative to a 'sleep' command.
echo "Waiting for External Secrets CRDs to be registered by the API server..."
for i in {1..120}; do
    if kubectl get crd secretstores.external-secrets.io &>/dev/null; then
        echo "External Secrets CRDs are ready."
        break
    fi
    echo -n "."
    sleep 1
    if [[ $i -eq 120 ]]; then
        echo -e "\nERROR: Timeout waiting for External Secrets CRDs to be ready."
        exit 1
    fi
done

# --- 7. Deploy External Secret Store and External Secret ---
echo "--- 7. Deploying External Secret Store and External Secret ---"
echo "--- Deploying External Secret Store and External Secret ---"

echo "Waiting for ALL External Secrets CRDs to be established..."
for crd in secretstores externalsecrets clustersecretstores clusterexternalsecrets; do
  kubectl wait --for=condition=Established crd/${crd}.external-secrets.io --timeout=300s || \
    handle_error "Timeout waiting for ${crd} CRD to be ready"
done

echo "All External Secrets CRDs are now ready."

# Add additional check for operator pods to be ready
echo "Waiting for External Secrets Operator pods to be ready..."
kubectl wait --for=condition=Ready pod -n "${EXTERNAL_SECRETS_NAMESPACE}" -l app.kubernetes.io/name=external-secrets --timeout=300s || \
  handle_error "External Secrets Operator pods not ready"

# Additional delay for API to stabilize
sleep 20

# Apply with server-side apply for better reliability
kubectl apply --server-side -f "${EXTERNAL_SECRET_CONFIG_FILE}" || \
  handle_error "Failed to apply External Secret configuration"

# --- 8. Deploy KEDA TriggerAuthentication (shared) ---
echo "--- 8. Deploying KEDA TriggerAuthentication (shared) ---"
echo "--- Deploying KEDA TriggerAuthentication (shared) ---"
kubectl apply -f "${KEDA_TRIGGER_AUTH_FILE}" || handle_error "Failed to deploy KEDA TriggerAuthentication"
echo "KEDA TriggerAuthentication deployed."


# --- 9. Deploy Application Resources for Each Topic ---
echo "--- 9. Deploying Application Resources for Each Topic ---"
# echo "--- Deploying Hello World Pub/Sub Applications for each topic ---"
# for TOPIC_ID in "${!TOPIC_CONFIGS[@]}"; do
#   SUBSCRIPTION_ID="${TOPIC_CONFIGS[$TOPIC_ID]}"
#   echo "Processing topic: ${TOPIC_ID} with subscription: ${SUBSCRIPTION_ID}"

for i in "${!TOPIC_IDS[@]}"; do
  TOPIC_ID="${TOPIC_IDS[i]}"
  SUBSCRIPTION_ID="${PUBSUB_SUBSCRIPTION_IDS[i]}"
  echo "Processing topic: ${TOPIC_ID} with subscription: ${SUBSCRIPTION_ID}"

  # ... rest of the loop content
done

  # Generate and apply Deployment for current topic
  TEMP_DEPLOYMENT_FILE=$(mktemp)
  sed -e "s|{{TOPIC_IDENTIFIER}}|${TOPIC_ID}|g" \
      -e "s|{{PUBSUB_SUBSCRIPTION_ID_VALUE}}|${SUBSCRIPTION_ID}|g" \
      -e "s|your-gcp-project-id|${GCP_PROJECT_ID}|g" \
      "${APP_DEPLOYMENT_TEMPLATE}" | \
  sed "s|<YOUR_AWS_ACCOUNT_ID>.dkr.ecr.<YOUR_AWS_REGION>.amazonaws.com/hello-keda-app:latest|${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}|g" \
  > "${TEMP_DEPLOYMENT_FILE}"

  kubectl apply -f "${TEMP_DEPLOYMENT_FILE}" || handle_error "Failed to deploy application deployment for ${TOPIC_ID}"
  rm "${TEMP_DEPLOYMENT_FILE}"

  # Generate and apply Service for current topic
  TEMP_SERVICE_FILE=$(mktemp)
  sed "s|{{TOPIC_IDENTIFIER}}|${TOPIC_ID}|g" "${APP_SERVICE_TEMPLATE}" > "${TEMP_SERVICE_FILE}"
  kubectl apply -f "${TEMP_SERVICE_FILE}" || handle_error "Failed to deploy application service for ${TOPIC_ID}"
  rm "${TEMP_SERVICE_FILE}"

  # Generate and apply KEDA ScaledObject for current topic
  TEMP_SCALER_FILE=$(mktemp)
  sed -e "s|{{TOPIC_IDENTIFIER}}|${TOPIC_ID}|g" \
      -e "s|{{PUBSUB_SUBSCRIPTION_ID_VALUE}}|${SUBSCRIPTION_ID}|g" \
      -e "s|your-gcp-project-id|${GCP_PROJECT_ID}|g" \
      "${KEDA_SCALER_TEMPLATE}" > "${TEMP_SCALER_FILE}"

  kubectl apply -f "${TEMP_SCALER_FILE}" || handle_error "Failed to deploy KEDA ScaledObject for ${TOPIC_ID}"
  rm "${TEMP_SCALER_FILE}"

  echo "Successfully deployed resources for topic: ${TOPIC_ID}"
done

# --- 10. Final Verification ---
echo "--- 10. Final Verification ---"
echo "--- Deployment Complete. Checking Resources ---"
echo "Pods in ${APP_NAMESPACE}:"
kubectl get pods -n "${APP_NAMESPACE}" -l app=hello-keda-app

echo "ScaledObjects in ${APP_NAMESPACE}:"
kubectl get scaledobject -n "${APP_NAMESPACE}"

echo "ExternalSecrets status in ${APP_NAMESPACE}:"
kubectl get externalsecret -n "${APP_NAMESPACE}"

echo "Pods in ${KEDA_NAMESPACE}:"
kubectl get pods -n "${KEDA_NAMESPACE}"

echo "Pods in ${EXTERNAL_SECRETS_NAMESPACE}:"
kubectl get pods -n "${EXTERNAL_SECRETS_NAMESPACE}"

echo "All resources deployed. Monitor pods and logs for application health and scaling behavior."
echo "You can now send messages to your GCP Pub/Sub topics to observe scaling."