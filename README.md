# EKS KEDA Multi-Pub/Sub Subscriber

This project demonstrates a Python application that processes messages from **multiple** Google Cloud Pub/Sub topics. Each topic's messages are handled by a **dedicated, independently scalable** Kubernetes Deployment on AWS EKS Fargate using KEDA. GCP credentials are securely managed via AWS Secrets Manager and External Secrets.

## Architecture Overview

* **GCP Pub/Sub:** Multiple topics act as event sources. Each topic has a dedicated subscription.
* **Python Subscriber App:** A single Dockerized Flask application image.
* **Multiple Kubernetes Deployments:** For N topics, N instances of the Python app deployment are created. Each deployment is configured to subscribe to *one specific* Pub/Sub subscription.
* **Multiple KEDA ScaledObjects:** Each Kubernetes Deployment has its own KEDA `ScaledObject` that monitors *only its specific* Pub/Sub subscription's backlog, enabling granular, per-topic scaling.
* **AWS Secrets Manager:** Stores a single GCP Service Account key securely.
* **External Secrets Operator:** Fetches the GCP key from AWS Secrets Manager and creates a single shared Kubernetes Secret.
* **AWS EKS Fargate:** The serverless compute environment for running Kubernetes pods.
* **IAM Roles for Service Accounts (IRSA):** Provides fine-grained AWS permissions to Kubernetes Service Accounts.

## Folder Structure
```
eks-keda-multi-pubsub-subscriber/
├── app/
│   ├── app.py                     # Generic Python Flask application (Pub/Sub subscriber)
│   └── requirements.txt           # Python dependencies
├── k8s/
│   ├── namespace.yml              # Kubernetes Namespace for the application
│   ├── deployment-template.yml    # Template for Kubernetes Deployments (one per topic)
│   ├── service-template.yml       # Template for Kubernetes Services (one per topic, optional)
│   ├── gcp-keda-scaler-template.yml # Template for KEDA ScaledObjects (one per topic)
│   ├── external-secret.yml        # External Secrets: SecretStore and ExternalSecret (shared)
│   ├── iam-role-service-account.yml # Kubernetes Service Accounts with IRSA annotations (shared)
│   └── trigger-authentication.yml # KEDA TriggerAuthentication for GCP credentials (shared)
├── eks-clusterconfig.yml          # eksctl configuration for EKS cluster and Fargate profiles
├── Dockerfile                     # Dockerfile for the Python application
├── deploy-pipeline.sh             # Main deployment script
└── README.md                      # This README file
```

## Prerequisites

1.  **AWS Account:** A brand new AWS account or one with administrative access.
2.  **GCP Account:** A brand new Google Cloud account or one with administrative access.
3.  **AWS CLI:** Configured with your AWS credentials.
4.  **kubectl:** Kubernetes command-line tool.
5.  **eksctl:** EKS command-line tool (version 0.100.0 or newer recommended).
6.  **Docker:** Docker installed and running on your local machine.
7.  **yq:** YAML processor (`brew install yq` on macOS, or follow [yq installation guide](https://mikefarah.gitbook.io/yq/#install)).
8.  **Helm:** Kubernetes package manager (`brew install helm` on macOS, or follow [Helm installation guide](https://helm.sh/docs/intro/install/)).
9.  **gcloud CLI:** Google Cloud SDK with `gcloud` command-line tool. Authenticate it: `gcloud auth login` and `gcloud config set project <YOUR_GCP_PROJECT_ID>`.

## Step-by-Step Setup Guide

This guide assumes you are starting with brand new AWS and GCP accounts.

### A. Google Cloud Platform (GCP) Setup

1.  **Create a New GCP Project:**
    * Go to [Google Cloud Console](https://console.cloud.google.com/).
    * Click the project selector dropdown at the top.
    * Click "New Project".
    * Give it a name (e.g., `keda-pubsub-eks-project`) and note down its **Project ID** (e.g., `keda-pubsub-eks-project-12345`). This ID is crucial.
    * Click "CREATE".

2.  **Enable Billing:**
    * Go to Navigation menu -> Billing.
    * Link a billing account to your new project if you haven't already.

3.  **Enable Pub/Sub API:**
    * Go to Navigation menu -> APIs & Services -> Enabled APIs & Services.
    * Click "+ ENABLE APIS AND SERVICES".
    * Search for "Cloud Pub/Sub API" and enable it.

4.  **Create Pub/Sub Topics and Subscriptions (3 Topics):**
    For each topic, you'll create a topic and a corresponding pull subscription.

    * Go to Navigation menu -> Pub/Sub -> Topics.
    * **Topic 1: `keda-topic-alpha`**
        * Click "CREATE TOPIC".
        * Topic ID: `keda-topic-alpha`
        * Click "CREATE TOPIC".
    * **Topic 2: `keda-topic-beta`**
        * Click "CREATE TOPIC".
        * Topic ID: `keda-topic-beta`
        * Click "CREATE TOPIC".
    * **Topic 3: `keda-topic-gamma`**
        * Click "CREATE TOPIC".
        * Topic ID: `keda-topic-gamma`
        * Click "CREATE TOPIC".

    * Go to Navigation menu -> Pub/Sub -> Subscriptions.
    * **Subscription 1: `my-pubsub-subscription-alpha`** (for `keda-topic-alpha`)
        * Click "CREATE SUBSCRIPTION".
        * Subscription ID: `my-pubsub-subscription-alpha`
        * Select topic: `keda-topic-alpha`
        * Delivery type: "Pull"
        * Click "CREATE".
    * **Subscription 2: `my-pubsub-subscription-beta`** (for `keda-topic-beta`)
        * Click "CREATE SUBSCRIPTION".
        * Subscription ID: `my-pubsub-subscription-beta`
        * Select topic: `keda-topic-beta`
        * Delivery type: "Pull"
        * Click "CREATE".
    * **Subscription 3: `my-pubsub-subscription-gamma`** (for `keda-topic-gamma`)
        * Click "CREATE SUBSCRIPTION".
        * Subscription ID: `my-pubsub-subscription-gamma`
        * Select topic: `keda-topic-gamma`
        * Delivery type: "Pull"
        * Click "CREATE".

5.  **Create GCP Service Account and Key (for Pub/Sub Subscriber):**
    This single service account will be used by all your Python app instances to authenticate with GCP Pub/Sub.

    * Go to Navigation menu -> IAM & Admin -> Service Accounts.
    * Select your project (`keda-pubsub-eks-project-12345`).
    * Click "+ CREATE SERVICE ACCOUNT".
    * Service account name: `eks-keda-pubsub-sa`
    * Click "CREATE AND CONTINUE".
    * **Grant this service account the following roles:**
        * `Pub/Sub Subscriber`
        * `Pub/Sub Viewer`
    * Click "CONTINUE".
    * Click "DONE".

    * Now, create a JSON key for this Service Account:
        * On the Service Accounts list, find `eks-keda-pubsub-sa`.
        * Click the three dots under "Actions" -> "Manage keys".
        * Click "ADD KEY" -> "Create new key".
        * Key type: "JSON"
        * Click "CREATE".
        * **A JSON file will be downloaded to your computer.** Open this file with a text editor. **Copy its ENTIRE content (including curly braces).** You will need this in the AWS Secrets Manager step. **Keep this file secure!**

### B. AWS Cloud Setup

1.  **Configure AWS CLI:**
    * Ensure your AWS CLI is configured with credentials that have administrative access or sufficient permissions to create EKS clusters, IAM roles, ECR repositories, and Secrets Manager secrets.
    * `aws configure`

2.  **Create EKS Cluster with Fargate Profiles:**
    * Ensure `eksctl` is installed.
    * **Open `eks-clusterconfig.yml`:**
        * Replace `us-east-1` with your desired `AWS_REGION`.
    * Create the EKS Cluster:
        ```bash
        eksctl create cluster -f eks-clusterconfig.yml
        ```
        This command will take 15-25 minutes. Do **NOT** proceed until it finishes successfully. It will also configure your `kubeconfig` automatically.

3.  **Create IAM Roles for Service Accounts (IRSA):**
    These roles will be assumed by your Kubernetes Service Accounts in EKS. You'll create the roles *first*, then link them using `eksctl` later.

    * **IAM Role for Python App (`keda-app-sa`):** This role needs permission to read the GCP secret from AWS Secrets Manager.
        * Go to AWS Console -> IAM -> Roles.
        * Click "Create role".
        * Trusted entity type: "Custom trust policy"
        * **Custom trust policy JSON:** (Temporary for creation, `eksctl` will update this later)
            ```json
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Principal": {
                            "AWS": "arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:root"
                        },
                        "Action": "sts:AssumeRole"
                    }
                ]
            }
            ```
            *Replace `<YOUR_AWS_ACCOUNT_ID>` with your AWS account ID (`aws sts get-caller-identity --query Account --output text`).*
        * Click "Next".
        * **Permissions:** Attach an **inline policy** (or create a managed policy and attach it).
            * Policy Name: `KedaAppSecretsManagerReader`
            * Policy JSON:
                ```json
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": "secretsmanager:GetSecretValue",
                            "Resource": "arn:aws:secretsmanager:<YOUR_AWS_REGION>:<YOUR_AWS_ACCOUNT_ID>:secret:gcp-pubsub-credentials-*"
                        }
                    ]
                }
                ```
                *Replace `<YOUR_AWS_REGION>` and `<YOUR_AWS_ACCOUNT_ID>`.*
        * Click "Next".
        * Role name: `EKS-KedaApp-SecretsReader-Role`
        * Click "Create role".
        * **MAKE A NOTE OF THE ARN FOR `EKS-KedaApp-SecretsReader-Role`** (e.g., `arn:aws:iam::123456789012:role/EKS-KedaApp-SecretsReader-Role`).

    * **IAM Role for External Secrets Operator (`external-secrets-sa`):** This role needs broader permissions to interact with Secrets Manager.
        * Go to AWS Console -> IAM -> Roles.
        * Click "Create role".
        * Trusted entity type: "Custom trust policy"
        * **Custom trust policy JSON:** (Temporary for creation, `eksctl` will update this later)
            ```json
            {
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Principal": {
                            "AWS": "arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:root"
                        },
                        "Action": "sts:AssumeRole"
                    }
                ]
            }
            ```
            *Replace `<YOUR_AWS_ACCOUNT_ID>`.*
        * Click "Next".
        * **Permissions:** Attach an **inline policy**.
            * Policy Name: `ExternalSecretsManagerAccess`
            * Policy JSON:
                ```json
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Action": [
                                "secretsmanager:GetSecretValue",
                                "secretsmanager:DescribeSecret",
                                "secretsmanager:ListSecrets"
                            ],
                            "Resource": "*" # Can be more restrictive if you know exact ARNs
                        }
                    ]
                }
                ```
        * Click "Next".
        * Role name: `EKS-ExternalSecrets-Reader-Role`
        * Click "Create role".
        * **MAKE A NOTE OF THE ARN FOR `EKS-ExternalSecrets-Reader-Role`** (e.g., `arn:aws:iam::123456789012:role/EKS-ExternalSecrets-Reader-Role`).

4.  **Store GCP Service Account Key in AWS Secrets Manager:**
    * Go to AWS Console -> Secrets Manager.
    * Click "Store a new secret".
    * Choose "Other type of secret".
    * **Key:** `gcp_sa_key` (This exact key name is used in `k8s/external-secret.yml`)
    * **Value:** Paste the **entire content** of your downloaded GCP JSON key file here.
    * Click "Next".
    * Secret name: `gcp-pubsub-credentials`
    * Click "Next" and "Store".
    * **MAKE A NOTE OF THE ARN FOR `gcp-pubsub-credentials`** (e.g., `arn:aws:secretsmanager:us-east-1:123456789012:secret:gcp-pubsub-credentials-XXXXXX`). This is for your reference, and is covered by the IAM policies.

### C. Update Project Files with Your Specific IDs

Now that you have your IDs and ARNs, update the placeholders in the project files.

1.  **Open `k8s/iam-role-service-account.yml`:**
    * Replace `<YOUR_AWS_ACCOUNT_ID>` and `<YOUR_IAM_ROLE_NAME_FOR_KEDA_APP_SA>` with the ARN of `EKS-KedaApp-SecretsReader-Role`.
    * Replace `<YOUR_AWS_ACCOUNT_ID>` and `<YOUR_IAM_ROLE_NAME_FOR_EXTERNAL_SECRETS_SA>` with the ARN of `EKS-ExternalSecrets-Reader-Role`.

2.  **Open `k8s/external-secret.yml`:**
    * Replace `us-east-1` with your `AWS_REGION`.

3.  **Open `k8s/deployment-template.yml`:**
    * Replace `your-gcp-project-id` with your GCP Project ID (e.g., `keda-pubsub-eks-project-12345`).
    * Replace `<YOUR_AWS_ACCOUNT_ID>` and `<YOUR_AWS_REGION>` in the image name.

4.  **Open `k8s/gcp-keda-scaler-template.yml`:**
    * Replace `your-gcp-project-id` with your GCP Project ID.

5.  **Open `deploy-pipeline.sh`:**
    * Replace `us-east-1` with your `AWS_REGION`.
    * Replace `your-gcp-project-id` with your GCP Project ID.
    * **Verify the `TOPIC_CONFIGS` map** matches the topic identifiers and subscription IDs you created in GCP:
        ```bash
        declare -A TOPIC_CONFIGS=(
          ["alpha"]="my-pubsub-subscription-alpha"
          ["beta"]="my-pubsub-subscription-beta"
          ["gamma"]="my-pubsub-subscription-gamma"
        )
        ```
    * Verify `KEDA_VERSION` and `EXTERNAL_SECRETS_HELM_CHART_VERSION` are the desired stable versions.

### D. Deploy to EKS

1.  **Grant IRSA Permissions to Service Accounts:**
    After your EKS cluster is created, you need to associate the Kubernetes Service Accounts with the IAM roles you created.

    ```bash
    # For the KEDA application's Service Account
    eksctl create iamserviceaccount \
        --name keda-app-sa \
        --namespace hello-keda-app \
        --cluster ${EKS_CLUSTER_NAME} \
        --attach-im-policy-arn arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:policy/KedaAppSecretsManagerReader  \
        --approve

    # For the External Secrets Operator's Service Account
    eksctl create iamserviceaccount \
        --name external-secrets-sa \
        --namespace external-secrets \
        --cluster ${EKS_CLUSTER_NAME} \
        --attach-im-policy-arn arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:policy/ExternalSecretsManagerAccess \
        --approve
    ```
    *Replace `<YOUR_AWS_ACCOUNT_ID>` and ensure the policy names/ARNs match what you created.*
    *These commands will create/update the trust policies on your IAM roles and add the `eks.amazonaws.com/role-arn` annotation to your Kubernetes Service Accounts.*

2.  **Make `deploy-pipeline.sh` executable:**
    ```bash
    chmod +x deploy-pipeline.sh
    ```

3.  **Run the deployment script:**
    ```bash
    ./deploy-pipeline.sh
    ```
    This script will:
    * Configure `kubectl` to connect to your EKS cluster.
    * Build the Docker image of your Python app and push it to AWS ECR.
    * Deploy KEDA core components.
    * Deploy External Secrets Operator (and mirror its images to ECR if needed).
    * Create the `hello-keda-app` and `external-secrets` Kubernetes namespaces.
    * Apply the shared `iam-role-service-account.yml`.
    * Apply `external-secret.yml` to set up the connection to AWS Secrets Manager.
    * Apply `trigger-authentication.yml`.
    * **Loop through each of your 3 topics:**
        * Generate a unique Deployment for each topic using `deployment-template.yml`.
        * Generate a unique Service for each topic using `service-template.yml`.
        * Generate a unique KEDA ScaledObject for each topic using `gcp-keda-scaler-template.yml`.
        * Apply these generated manifests to Kubernetes.
    * Perform final verification checks.

### E. Verification and Testing

1.  **Check Pods in `hello-keda-app` namespace:**
    ```bash
    kubectl get pods -n hello-keda-app
    ```
    Initially, you should see 0 replicas for each of your topic-specific deployments (e.g., `hello-keda-app-alpha-deployment-XXXXX-YYYYY`, `hello-keda-app-beta-deployment-XXXXX-YYYYY`, etc.). This confirms KEDA has scaled them down.

2.  **Check KEDA ScaledObjects:**
    ```bash
    kubectl get scaledobject -n hello-keda-app
    ```
    You should see three `ScaledObject` resources, one for each topic (e.g., `hello-keda-pubsub-scaler-alpha`, `hello-keda-pubsub-scaler-beta`, etc.), all showing `Ready` and `Not Active` status.

3.  **Check External Secret:**
    ```bash
    kubectl get externalsecret -n hello-keda-app
    kubectl get secret gcp-pubsub-credentials-k8s -n hello-keda-app -o yaml
    ```
    The `ExternalSecret` should be `Ready`, and the Kubernetes `Secret` should exist and contain the `key.json` data.

4.  **Send Sample Messages to Topics:**
    Now, let's send some messages to your GCP Pub/Sub topics to see the scaling in action!

    * **Using GCP Cloud Console:**
        * Go to Navigation menu -> Pub/Sub -> Topics.
        * Select `keda-topic-alpha`. Click "PUBLISH MESSAGE".
        * Enter "Hello from Alpha!" as the message body. Click "PUBLISH".
        * Repeat this a few times for `keda-topic-alpha` (e.g., 10-20 messages).
        * Do the same for `keda-topic-beta` (e.g., 2 messages).
        * Do not send messages to `keda-topic-gamma` yet.

    * **Using `gcloud` CLI:**
        * Make sure your `gcloud` CLI is authenticated and configured to your project.
        * Send messages to `keda-topic-alpha`:
            ```bash
            gcloud pubsub topics publish keda-topic-alpha --message="Test message from alpha 1"
            gcloud pubsub topics publish keda-topic-alpha --message="Test message from alpha 2"
            # ... send more messages ...
            ```
        * Send messages to `keda-topic-beta`:
            ```bash
            gcloud pubsub topics publish keda-topic-beta --message="Test message from beta 1"
            gcloud pubsub topics publish keda-topic-beta --message="Test message from beta 2"
            ```
        * Do not send messages to `keda-topic-gamma` yet.

5.  **Observe Scaling:**
    * Open a new terminal and continuously monitor your pods:
        ```bash
        kubectl get pods -n hello-keda-app -l app=hello-keda-app --watch
        ```
    * Within 30 seconds (your `pollingInterval`), you should see the `hello-keda-app-alpha-deployment` scale up (e.g., from 0/1 to 1/1, then 2/2, etc., depending on backlog).
    * You should see `hello-keda-app-beta-deployment` scale up to perhaps 1 replica.
    * Crucially, `hello-keda-app-gamma-deployment` should remain at 0 replicas because its topic has no messages.
    * Check the logs of the scaling pods:
        ```bash
        kubectl logs -f <POD_NAME_FOR_ALPHA> -n hello-keda-app
        kubectl logs -f <POD_NAME_FOR_BETA> -n hello-keda-app
        ```
        You should see messages being processed and acknowledged, with the `topic_identifier` in the logs.

6.  **Observe Scale Down:**
    * Once all messages for a topic are processed, KEDA will detect the empty backlog. After the `cooldownPeriod` (300 seconds by default), the corresponding deployment will scale back down to `minReplicaCount` (which is 0).

### F. Cleaning Up Your Cloud Resources

**Order of operations is important for cleanup!**

1.  **Delete Application Resources:**
    ```bash
    # Iterate and delete resources for each topic
    for TOPIC_ID in "alpha" "beta" "gamma"; do
        kubectl delete deployment hello-keda-app-${TOPIC_ID}-deployment -n hello-keda-app
        kubectl delete service hello-keda-app-${TOPIC_ID}-service -n hello-keda-app
        kubectl delete scaledobject hello-keda-pubsub-scaler-${TOPIC_ID} -n hello-keda-app
    done

    # Delete shared resources in app namespace
    kubectl delete -f k8s/external-secret.yml -n hello-keda-app # This deletes the ExternalSecret and the K8s Secret it created
    kubectl delete -f k8s/iam-role-service-account.yml -n hello-keda-app # Delete the SA for your app
    kubectl delete -f k8s/trigger-authentication.yml -n hello-keda-app
    kubectl delete namespace hello-keda-app --timeout=5m # Wait for namespace termination
    ```

2.  **Delete External Secrets Operator:**
    ```bash
    helm uninstall external-secrets -n external-secrets
    kubectl delete -f k8s/iam-role-service-account.yml -n external-secrets # Delete the SA for ES operator
    kubectl delete namespace external-secrets --timeout=5m
    # Optionally, delete CRDs if no other external-secrets instances are needed:
    # kubectl delete crd clustersecretstores.external-secrets.io
    # kubectl delete crd externalsecrets.external-secrets.io
    # kubectl delete crd secretstores.external-secrets.io
    ```

3.  **Delete KEDA Operator:**
    ```bash
    kubectl delete -f [https://github.com/kedacore/keda/releases/download/v$](https://github.com/kedacore/keda/releases/download/v$){KEDA_VERSION}/keda-${KEDA_VERSION}-core.yaml --timeout=5m
    kubectl delete -f [https://github.com/kedacore/keda/releases/download/v$](https://github.com/kedacore/keda/releases/download/v$){KEDA_VERSION}/keda-${KEDA_VERSION}-crds.yaml --timeout=5m
    kubectl delete namespace keda --timeout=5m
    ```

4.  **Delete ECR Repositories:**
    ```bash
    aws ecr delete-repository --repository-name hello-keda-app --force --region ${AWS_REGION}
    aws ecr delete-repository --repository-name external-secrets/external-secrets --force --region ${AWS_REGION}
    aws ecr delete-repository --repository-name external-secrets/external-secrets-webhook --force --region ${AWS_REGION}
    ```

5.  **Delete AWS Secrets Manager Secret:**
    * Go to AWS Console -> Secrets Manager.
    * Find `gcp-pubsub-credentials`.
    * Click "Actions" -> "Delete secret".
    * Type the secret name to confirm and click "Delete".

6.  **Delete IAM Roles:**
    * Go to AWS Console -> IAM -> Roles.
    * Find and delete `EKS-KedaApp-SecretsReader-Role`.
    * Find and delete `EKS-ExternalSecrets-Reader-Role`.

7.  **Delete EKS Cluster (BE CAREFUL - THIS IS DESTRUCTIVE!):**
    ```bash
    eksctl delete cluster -f eks-clusterconfig.yml
    ```
    This will take 10-20 minutes to complete.

8.  **Delete GCP Pub/Sub Resources & Service Account:**
    * Go to Google Cloud Console.
    * Delete all subscriptions (`my-pubsub-subscription-alpha`, etc.).
    * Delete all topics (`keda-topic-alpha`, etc.).
    * Go to IAM & Admin -> Service Accounts. Delete `eks-keda-pubsub-sa`.
    * Finally, you can delete your GCP project if you no longer need it. Go to IAM & Admin -> Settings -> "DELETE PROJECT".

This complete guide should get you from scratch to a fully functional, scalable multi-topic Pub/Sub processing system on EKS Fargate!
