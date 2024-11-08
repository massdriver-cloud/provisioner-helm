#!/bin/bash

set -eo pipefail

entrypoint_dir="/massdriver"

params_path="$entrypoint_dir/params.json"
connections_path="$entrypoint_dir/connections.json"
config_path="$entrypoint_dir/config.json"
envs_path="$entrypoint_dir/envs.json"
secrets_path="$entrypoint_dir/secrets.json"

# Extract provisioner configuration
name_prefix=$(jq -r '.md_metadata.name_prefix' "$params_path")
release_name=$(jq -r --arg name_prefix "$name_prefix" '.release_name // $name_prefix' "$config_path")
namespace=$(jq -r '.namespace // "default"' "$config_path")

# Extract auth
# Try to get Kubernetes authentication from config.json, then fall back to connections.json
k8s_auth=$(jq -r '.kubernetes_cluster // empty' "$config_path" 2>/dev/null || true)

if [ -z "$k8s_auth" ]; then
  k8s_auth=$(jq -r '.kubernetes_cluster // empty' "$connections_path" 2>/dev/null || true)
fi

# Check if k8s_auth is still empty, and exit since we don't have auth info
if [ -z "$k8s_auth" ]; then
  echo "Error: No kubernetes credentials found. Please refer to the provisioner documentation for specifying kubernetes credentials."
  exit 1
fi

# Extract fields from kubernetes_cluster and validate they are not empty
k8s_apiserver=$(echo "$k8s_auth" | jq -r '.data.authentication.cluster.server // empty')
k8s_token=$(echo "$k8s_auth" | jq -r '.data.authentication.user.token // empty')
k8s_cacert_file="${entrypoint_dir}/ca_cert.pem"
echo "$k8s_auth" | jq -r '.data.authentication.cluster."certificate-authority-data" // empty' | base64 -d > "$k8s_cacert_file"

if [ -z "$k8s_apiserver" ]; then
  echo "Error: Missing required field "server" in kubernetes credentials. Please refer to the provisioner documentation for specifying kubernetes credentials."
  exit 1
fi
if [ -z "$k8s_token" ]; then
  echo "Error: Missing required field "token" in kubernetes credentials. Please refer to the provisioner documentation for specifying kubernetes credentials."
  exit 1
fi
if [ ! -s "$k8s_cacert_file" ]; then
    echo "Error: Missing required field "certificate-authority-data" in kubernetes credentials. Please refer to the provisioner documentation for specifying kubernetes credentials."
    exit 1
fi

cd "bundle/$MASSDRIVER_STEP_PATH"

# Generate connection values YAML from connections.jq or default to full JSON
if [ -f connections.jq ]; then
    jq -f connections.jq "$connections_path" | yq -p=json > connections_values.yaml
else
    yq -p=json < "$connections_path" > connections_values.yaml
fi

# Generate parameter values YAML from params.jq or default to full JSON
if [ -f params.jq ]; then
    jq -f params.jq "$params_path" | yq -p=json > params_values.yaml
else
    yq -p=json < "$params_path" > params_values.yaml
fi

# Determine Helm command based on deployment action
helm_command=""
case "$MASSDRIVER_DEPLOYMENT_ACTION" in

  plan)
    helm_command="upgrade $release_name . --dry-run -i --namespace $namespace --create-namespace -f connections_values.yaml -f params_values.yaml --debug --wait"
    ;;

  provision)
    helm_command="upgrade $release_name . -i --namespace $namespace --create-namespace -f connections_values.yaml -f params_values.yaml --debug --wait"
    ;;

  decommission)
    helm_command="uninstall $release_name --namespace $namespace --debug --wait"
    ;;

  *)
    echo "Error: Unsupported deployment action '$MASSDRIVER_DEPLOYMENT_ACTION'. Expected 'plan', 'provision', or 'decommission'."
    exit 1
    ;;

esac

helm $helm_command --kube-apiserver $k8s_apiserver --kube-token $k8s_token --kube-ca-file "$k8s_cacert_file"

# Handle artifacts if deployment action is 'provision' or 'decommission'
case "$MASSDRIVER_DEPLOYMENT_ACTION" in
  provision )
    helm --kube-apiserver $k8s_apiserver --kube-token $k8s_token --kube-ca-file "$k8s_cacert_file" get manifest $release_name --namespace $namespace | yq ea -o=json '[.]' > outputs.json
    jq -s '{params:.[0],connections:.[1],outputs:.[2]}' "$params_path" "$connections_path" outputs.json > artifact_inputs.json
    for artifact_file in artifact_*.jq; do
        [ -f "$artifact_file" ] || break
        field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
        echo "Creating artifact for field $field"
        jq -f "$artifact_file" artifact_inputs.json | xo artifact publish -d "$field" -n "Artifact $field for helm release $release_name" -f -
    done
    ;;
  decommission )
    for artifact_file in artifact_*.jq; do
        [ -f "$artifact_file" ] || break
        field=$(echo "$artifact_file" | sed 's/^artifact_\(.*\).jq$/\1/')
        echo "Deleting artifact for field $field"
        xo artifact delete -d "$field" -n "Artifact $field for helm release $release_name"
    done
    ;;
esac