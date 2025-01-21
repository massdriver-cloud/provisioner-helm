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
debug=$(jq -r '.debug // true' "$config_path")
timeout=$(jq -r '.timeout // empty' "$config_path")
wait=$(jq -r '.wait // true' "$config_path")
wait_for_jobs=$(jq -r '.wait_for_jobs // true' "$config_path")

# Extract Checkov configuration
checkov_enabled=$(jq -r '.checkov.enable // true' "$config_path")
checkov_quiet=$(jq -r '.checkov.quiet // true' "$config_path")
checkov_halt_on_failure=$(jq -r '.checkov.halt_on_failure // false' "$config_path")

evaluate_checkov() {
    if [ "$checkov_enabled" = "true" ]; then
        echo "Evaluating Checkov policies..."
        checkov_flags=""

        if [ "$checkov_quiet" = "true" ]; then
            checkov_flags+=" --quiet"
        fi
        if [ "$checkov_halt_on_failure" = "false" ]; then
            checkov_flags+=" --soft-fail"
        fi

        checkov -d . --framework helm --var-file params_values.yaml --var-file connections_values.yaml --var-file envs_values.yaml --var-file secrets_values.yaml $checkov_flags
    fi
}

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
    yq -p=json -o=yaml < "$connections_path" > connections_values.yaml
fi

# Generate parameter values YAML from params.jq or default to full JSON
if [ -f params.jq ]; then
    jq -f params.jq "$params_path" | yq -p=json > params_values.yaml
else
    yq -p=json -o=yaml < "$params_path" > params_values.yaml
fi

# Generate envs values YAML from envs.jq or default to full JSON nested under "envs"
if [ -f envs.jq ]; then
    jq -f envs.jq "$envs_path" | yq -p=json > envs_values.yaml
else
    yq -p=json -o=yaml '{"envs": .}' < "$envs_path" > envs_values.yaml
fi

# Generate secrets values YAML from secrets.jq or default to full JSON nested under "secrets"
if [ -f secrets.jq ]; then
    jq -f secrets.jq "$secrets_path" | yq -p=json > secrets_values.yaml
else
    yq -p=json -o=yaml '{"secrets": .}' < "$secrets_path" > secrets_values.yaml
fi

# extract helm args from config
helm_args=""

if [ "$debug" = "true" ]; then
    helm_args+=" --debug"
fi

if [ "$wait" = "true" ]; then
    helm_args+=" --wait"
fi

if [ "$wait_for_jobs" = "true" ] && [ "$MASSDRIVER_DEPLOYMENT_ACTION" != "decommission" ]; then
    helm_args+=" --wait-for-jobs"
fi

if [ -n "$timeout" ]; then
    helm_args+=" --timeout $timeout"
fi

# Determine Helm command based on deployment action
helm_command=""
case "$MASSDRIVER_DEPLOYMENT_ACTION" in

  plan)
    evaluate_checkov
    helm_command="upgrade $release_name . --dry-run --install --namespace $namespace --create-namespace -f connections_values.yaml -f params_values.yaml -f envs_values.yaml -f secrets_values.yaml"
    ;;

  provision)
    evaluate_checkov
    helm_command="upgrade $release_name . --install --namespace $namespace --create-namespace -f connections_values.yaml -f params_values.yaml -f envs_values.yaml -f secrets_values.yaml"
    ;;

  decommission)
    helm_command="uninstall $release_name --namespace $namespace"
    ;;

  *)
    echo "Error: Unsupported deployment action '$MASSDRIVER_DEPLOYMENT_ACTION'. Expected 'plan', 'provision', or 'decommission'."
    exit 1
    ;;

esac

helm $helm_command $helm_args --kube-apiserver $k8s_apiserver --kube-token $k8s_token --kube-ca-file "$k8s_cacert_file"

# Handle artifacts if deployment action is 'provision' or 'decommission'
case "$MASSDRIVER_DEPLOYMENT_ACTION" in
  provision )
    helm --kube-apiserver $k8s_apiserver --kube-token $k8s_token --kube-ca-file "$k8s_cacert_file" get manifest $release_name --namespace $namespace | yq ea -o=json '[.]' > outputs.json
    jq -s '{params:.[0],connections:.[1],envs:.[2],secrets:.[3],outputs:.[4]}' "$params_path" "$connections_path" "$envs_path" "$secrets_path" outputs.json > artifact_inputs.json
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
