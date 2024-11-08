![helm](logo.svg)
# Massdriver Helm Provisioner

[Massdriver](https://www.massdriver.cloud/) provisioner for managing resources with [Helm](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/).

## Structure

This provisioner expects the `path` to be the base directory of a helm chart. This means it should contain the `Chart.yaml` and `values.yaml` files at a minimium.

## Tooling

The following tools are included in this provisioner:

* [Checkov](https://www.checkov.io/): Included to scan helm charts for common policy and compliance violations.

## Configuration

The following configuration options are available:

| Configuration Option | Type | Default | Description |
|-|-|-|-|
| `namespace` | string | `"default"` | Kubernetes namespace to install the chart into. Defaults to the `default` namespace |
| `release_name` | string | \<package name> | Specifies the release name for the helm chart. Defaults to the Massdriver package name if not specified. |
| `checkov.enable` | boolean | `true` | Enables Checkov policy evaluation. If `false`, Checkov will not be run. |
| `checkov.quiet` | boolean | `true` | Only display failed checks if `true` (adds the `--quiet` flag). |
| `checkov.halt_on_failure` | boolean | `false` | Halt provisioning run and mark deployment as failed on a policy failure (removes the `--soft-fail` flag). |

## Inputs

Helm accepts inputs via YAML formatted files, the primary one being [values.yaml](https://helm.sh/docs/chart_template_guide/values_files/), though additional files can be specified. To adhere to this standard, this provisioner will convert the `params.json` and `connections.json` files into YAML format before passing them to Helm.

If modifications to params or connections are required to fit the predefined values of a helm chart, this provisioner supports JQ templates for restructuring both the `params.json` and `connections.json` files before they are converted to YAML. These JQ template files should exist in the base directory of the helm chart and be named `params.jq` and `connections.jq`, respectively. The format of these files should be a JQ template which accepts the `params.json` and `connections.json` files as inputs and restructures them according to the JQ template. These files aren't required by the provisioner so if either of them is missing the corresponding JSON file will be left unmodified.

To demonstrate, let's say there is a Helm bundle with some configuration values and a dependency on a Postgres database. The `values.yaml` file would be something like this:

```yaml values.yaml
commonLabels: {}

foo:
    bar: "baz"
    count: 4

postgres:
    hostname: ""
    port: 5432
    user: "root"
    password: ""
    version: "12.1"
```

To properly set these values in a Massdriver bundle, we likely would want the labels to come from [`md_metadata.default_tags`](https://docs.massdriver.cloud/bundles/development#massdriver-metadata), the `foo` value to come from params, and the `postgres` block to come from a connection. That means this bundle would require a `massdriver/postgres-authentication` connection named `database`. Since this is a Helm chart, it will also need a `massdriver/kubernetes-cluster` connection to provide authentication to the kubernetes cluster the chart is being installed into. The `massdriver.yaml` file would look something like:

```yaml massdriver.yaml
params:
  required:
    - foo
  properties:
    foo:
      required:
        - bar
        - count
      properties:
        bar:
          type: string
        count:
          type: integer

connections:
  required:
    - kubernetes_cluster
    - database
  properties:
    kubernetes_cluster:
      $ref: massdriver/kubernetes-cluster
    database:
      $ref: massdriver/postgresql-authentication
```
### params.jq

Let's start with the `params.json`, which will look like:

```json params.json
{
    "foo": {
        "bar": "bizzle",
        "count": 10
    },
    "md_metadata": {
        "default_tags": {
            "managed-by": "massdriver",
            "md-manifest": "man",
            "md-package": "proj-env-man-0000",
            "md-project": "proj",
            "md-target": "env"
        },
        "name_prefix": "proj-env-man-0000"
        ...
    }
}
```

The `foo` object can be passed directly to helm chart since it already matches the structure in `values.yaml`. However, we want set `commonLabels` to `md_metadata.default_tags`, and we'd also like to remove the rest of `md_metadata` from the params since it isn't expected by the helm chart and could cause issues in the unlikely event there is a naming collision with an existing value named `md_metadata`. This means the `params.jq` file should contain:

```json params.jq
. += {"commonLabels": .md_metadata.default_tags} | del(.md_metadata)
```

This JQ command takes all of the original JSON and adds the field `commonLabels` which is set to `.md_metadata.default_tags`. It then deletes the entire `.md_metadata` block from the params. The resulting `params.yaml` after this JQ restructuring and conversion to YAML would be:

```yaml params.yaml
commonLabels:
    managed-by: "massdriver",
    md-manifest: "man",
    md-package: "proj-env-man-0000",
    md-project: "proj",
    md-target: "env"
foo:
    bar: "baz"
    count: 4
```

This fits what the helm chart expects. Now let's focus on connections.

### connections.jq

With the `database` and `kubernetes_cluster` connection, the `connections.json` file would be roughly equivalent to:

```json connections.json
{
    "kubernetes_cluster": {
        "data": {
            "authentication": {
                "cluster": {
                    "certificate-authority-data": "...",
                    "server": "https://my.kubernetes.cluster.com"
                },
                "user": {
                    "token": "..."
                }
            }
        },
        "specs": {
            "kubernetes": {
                "version": "1.27"
            }
        }
    },
    "database": {
        "data": {
            "authentication": {
                "hostname": "the.postgres.database",
                "password": "s3cr3tV@lue",
                "port": 5432,
                "username": "admin"
            }
        },
        "specs": {
            "rdbms": {
                "version": "14.6"
            }
        }
    }
}
```

While this `connections.json` file contains all the necessary data for the postgres configuration, it isn't formatted properly and there is significantly more data than needed by the chart. The entire `kubernetes_cluster` block isn't used by the Helm chart at all (it is only needed to provide the provisioner with authentication information to the Kubernetes cluster). Let's create a `connections.jq` file to remove the `kubernetes_cluster` connection, and restructure the `database` connection so that it fits the helm chart's expected `postgres` block.

```json connections.jq
{
    postgres: {
        hostname: .database.data.authentication.hostname
        port: .database.data.authentication.port
        user: .database.data.authentication.username
        password: .database.data.authentication.password
        version: .database.specs.version
    }
}
```

This will restructure the data so that the `connections.yaml` file passed to helm will be:

```yaml connections.yaml
postgres:
    hostname: "the.postgres.database"
    port: 5432
    user: "admin"
    password: "s3cr3tV@lue"
    version: "14.6"
```

This converts the data in `connections.json` to match the expected fields in `values.yaml`.

## Artifacts

After every provision, this provider will scan the template directory for files matching the pattern `artifact_<name>.jq`. If a file matching this pattern is present, it will be used as a JQ template to render and publish a Massdriver artifact. The inputs to the JQ template will be a JSON object with the params, connections and [helm manifests](https://helm.sh/docs/helm/helm_get_manifest/) as top level fields. Note that the `params` and `connections` will contain the original content of `params.json` and `connections.json`, without any modifications that may have been applied through `params.jq` and `connections.jq`. Since the output of `helm get manifest` is list of yaml files, the `outputs` block will be a JSON array with each element being an individual kubernetes resource manifest.

```json
{
    "params": {
        ...
    },
    "connections": {
        ...
    },
    "outputs": [
        ...
    ]
}
```

To demonstrate, let's say there is a Azure Storage Account bundle with a single param (`region`), a single connection (`azure_service_principal`), and a single artifact (`storage_account`). The `massdriver.yaml` would be similar to:


```yaml massdriver.yaml
params:
  required:
    - region
  properties:
    region:
      type: string

connections:
  required:
    - azure_service_principal
  properties:
    azure_service_principal:
      $ref: massdriver/azure-service-principal

artifacts:
  required:
    - storage_account
  properties:
    storage_account:
      $ref: massdriver/azure-storage-account-blob
```

In this example a file named `artifact_storage_account.jq` would need to be in the template directory and the provisioner would use this file as a JQ template, passing the params, connections and outputs to it. There are two approaches to building the proper artifact structure:
1. Fully render the artifact in the Bicep output
2. Build the artifact structure using the JQ template

Here are examples of each approach.

#### Fully Render as Bicep Output

If you choose to fully render the artifact in a Bicep output, it would be similar to:

```bicep
param region string

resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  ...
}

output artifact_storage_account object = {
    data:  {
        infrastructure: {
            ari: storageAccount.id
            endpoint: storageAccount.properties.primaryEndpoints.blob
        }
        security: {}
    }
    specs: {
        azure: {
            region: region
        }
    }
}
```

In this case, the input to the `artifact_storage_account.jq` template file would be:

```json
{
    "params": {
        "region": "eastus"
    },
    "connections": {
        "azure_service_principal": {
            "data": {
                "client_id": "00000000-1111-2222-3333-444444444444",
                "client_secret": "s0mes3cr3tv@lue",
                "subscription_id": "00000000-1111-2222-3333-444444444444",
                "tenant_id": "00000000-1111-2222-3333-444444444444"
            }
        }
    },
    "outputs": {
        "artifact_storage_account": {
            "value": {
                "data": {
                    "infrastructure": {
                        "ari": "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/resource-group-name/providers/Microsoft.Storage/storageAccounts/storageaccountname",
                        "endpoint": "https://storageaccountname.blob.core.windows.net/"
                    },
                    "security": {}
                },
                "specs": {
                    "azure": {
                        "region": "eastus"
                    }
                }
            }
        }
    }
}
```

Thus, the `artifact_storage_account.jq` file would simply be:

```json
.outputs.artifact_storage_account.value
```

#### Build Artifact in JQ Template

Alternatively, you can build the artifact structure using the JQ template. This approach is best if you are attempting to minimize changes to your Bicep template. With this approach, you would need to output the storage account ID and endpoint.

```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-04-01' = {
  ...
}

output storageAccountId string = storageAccount.id
output storageAccountEndpoint string = storageAccount.properties.primaryEndpoints.blob
```

In this case, the input to the `artifact_storage_account.jq` template file would be:

```json
{
    "params": {
        "region": "eastus"
    },
    "connections": {
        "azure_service_principal": {
            "data": {
                "client_id": "00000000-1111-2222-3333-444444444444",
                "client_secret": "s0mes3cr3tv@lue",
                "subscription_id": "00000000-1111-2222-3333-444444444444",
                "tenant_id": "00000000-1111-2222-3333-444444444444"
            }
        }
    },
    "outputs": {
        "storageAccountEndpoint": {
            "type": "String",
            "value": "https://storageaccountname.blob.core.windows.net/"
        },
        "storageAccountId": {
            "type": "String",
            "value": "/subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/resource-group-name/providers/Microsoft.Storage/storageAccounts/storageaccountname"
        }
    }
}
```

Now the artifact structure must be built through the `artifact_storage_account.jq` template:

```json
{
    "data":  {
        "infrastructure": {
            "ari": .outputs.storageAccountId.value,
            "endpoint": .outputs.storageAccountEndpoint.value
        },
        "security": {}
    },
    "specs": {
        "azure": {
            "region": .params.region
        }
    }
}
```