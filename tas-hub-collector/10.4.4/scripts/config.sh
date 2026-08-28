#!/bin/bash

export HUB_ADMIN_USER="tanzu_platform_admin"
export HUB_HOSTNAME="hub.${ENV_NAME}.cf-app.com"
export EARUAA_TARGET="https://login.sys.${ENV_NAME}.cf-app.com"

export TPST_CLIENT_ID="tpst-client"
export TPST_CLIENT_SECRET=$(base64 < /dev/urandom | tr -Cd 'a-zA-Z0-9' | tr -d 'AEIOUYaeiouy1340' | head -c 16)

# Source library files after ALL variables are defined
source $CONFIG_DIR/${PRODUCT_SLUG}/${PRODUCT_VERSION}/scripts/lib/common.sh

om() { command om -k "$@"; }

# Extract the AZ list from the director config and then construct
# different formats of that information for use in interpolation
# variables.
#
# First, extract AZ names into an array ...
azs=($(om staged-director-config | om interpolate --path '/az-configuration' | awk '/^ *name:/ { print $2; }'))

# Reformat into different forms ...
az_list="[$(echo ${azs[*]} | sed -e 's/ /, /g')]"     # [z1, z2, z3]
single_az=${azs[0]}                                   # z1
az_name_list=$(printf "{name: %s}, " ${azs[*]})       # Intermediate: {name: z2}, {name: z2}, {name: z3},
az_name_list="[${az_name_list%, }]"                   # Final: [{name: z2}, {name: z2}, {name: z3}]

# Now other variables we need for the config
environment_tag=${OM_HOSTNAME#pcf.}
environment_tag=${environment_tag%%.*}

# Perform configuration so we can access the Hub K8S cluster

om bosh-env > bosh_env.sh
export BOSH_ALL_PROXY="ssh+socks5://ubuntu@${OM_HOSTNAME}:8022?private-key=$(pwd)/opsman.key"
source bosh_env.sh
bosh instances --json > instances.json

    INSTANCES=$(bosh instances --json)
    K8S_MASTER_IP=$(echo ${INSTANCES} | jq -r '.Tables[].Rows[] | select((.instance | startswith("system/")) and (.deployment | startswith("hub-"))).ips')
    REGISTRY_INSTANCE_INFO=$(echo ${INSTANCES} | jq -r '.Tables[].Rows[] | select((.instance | startswith("registry/")) and (.deployment | startswith("hub-")))')
    REGISTRY_INSTANCE_NAME=$(echo "${REGISTRY_INSTANCE_INFO}" | jq -r '.instance')
    HUB_DEPLOYMENT_NAME=$(echo "${REGISTRY_INSTANCE_INFO}" | jq -r '.deployment')

    # Get kubeconfig using SSH instead of SCP
    echo "Fetching kubeconfig from ${REGISTRY_INSTANCE_NAME}..." >&2
    bosh -d ${HUB_DEPLOYMENT_NAME} scp ${REGISTRY_INSTANCE_NAME}:/var/vcap/jobs/hubsm-install/config/kubeconfig /tmp/

    TOKEN=$(cat /tmp/kubeconfig | yq '.users[0].user.token')

    KUBECONFIG="/tmp/config"

    cat << EOF > ${KUBECONFIG}
apiVersion: v1
kind: Config
clusters:
  - name: kubernetes
    cluster:
      insecure-skip-tls-verify: true
      server: https://localhost:8443
contexts:
  - name: context
    context:
      cluster: kubernetes
      user: admin
users:
  - name: admin
    user:
      token: ${TOKEN}
current-context: context
EOF

    # Set up SSH tunnel for kubectl
    echo "Setting up SSH tunnel for kubectl access..." >&2
    
    # Kill any existing SSH tunnels to avoid conflicts
    pkill -f "ssh.*${OM_HOSTNAME}" 2>/dev/null || true
    sleep 1
    
    # Create port forwarding tunnel: local 8443 -> K8S_MASTER_IP:8443 via OM_HOSTNAME
    echo "Creating SSH tunnel: localhost:8443 -> ${K8S_MASTER_IP}:8443 via ${OM_HOSTNAME}" >&2
    ssh -L 8443:${K8S_MASTER_IP}:8443 -N -f -o StrictHostKeyChecking=no -i opsman.key ubuntu@${OM_HOSTNAME} -p 8022
    
    # Wait for tunnel to establish
    sleep 2
    
    # Test tunnel connectivity
    if ! nc -z localhost 8443 2>/dev/null; then
        echo "Warning: SSH tunnel may not be established yet" >&2
    else
        echo "SSH tunnel established successfully" >&2
    fi

export KUBECONFIG=${KUBECONFIG}

echo "Setting Hub admin user password to non expiring..."

kubectl -n tanzusm exec postgresql-0 -c pg-container -- \
    psql -d uaa -c "update users set passwd_change_required = false where username = '${HUB_ADMIN_USER}'"

# Make Tanzu Hub embeddable in a cross-site iframe (Educates workshops)
HUB_FQDN="${HUB_HOSTNAME}" $CONFIG_DIR/${PRODUCT_SLUG}/${PRODUCT_VERSION}/scripts/lib/iframe-embed-overlays.sh

# Set credentials required for the Tanzu Hub CLI
export HUB_TARGET=${HUB_HOSTNAME}
export HUB_USERNAME=${HUB_ADMIN_USER}
export HUB_PASSWORD=$(om credentials --product-name hub --credential-reference .properties.admin_password --credential-field secret)

# Add the Tanzu Hub license
th -k license add --key ${HUB_LICENSE_KEY}

# Create a TPST client in the OM UAA to be used for Platform Services configuration
uaac target ${OM_TARGET}/uaa --skip-ssl-validation
uaac token owner get opsman ${OM_USERNAME} -s '' -p "${OM_PASSWORD}"
uaac client delete ${TPST_CLIENT_ID} || true
uaac client add ${TPST_CLIENT_ID} --secret "${TPST_CLIENT_SECRET}" \
  --authorized_grant_types client_credentials,refresh_token \
  --authorities 'opsman.admin opsman.full_control opsman.restricted_control opsman.full_view opsman.restricted_view scim.read'

# Need to create a tanzu_platform_admin user to match what is in Hub and add permissions
export EARADMIN_PASSWORD=$(om credentials --product-name cf --credential-reference .uaa.admin_client_credentials --credential-field password)
uaac target ${EARUAA_TARGET}
uaac token client get admin -s "${EARADMIN_PASSWORD}"
uaac user add tanzu_platform_admin --email "admin@test.org" --password "${HUB_PASSWORD}"
uaac member add cloud_controller.admin tanzu_platform_admin
uaac member add uaa.admin tanzu_platform_admin
uaac member add scim.read tanzu_platform_admin
uaac member add scim.write tanzu_platform_admin

# Define collector name based on environment
COLLECTOR_NAME="${ENV_NAME}-tas-collector"
echo "Using collector name: ${COLLECTOR_NAME}" >&2

COLLECTOR_VERSIONS=$(om available-products --format json | jq '.[] | select(.name == "hub-tas-collector").version' -r)
COLLECTOR_VERSION=$(echo "${COLLECTOR_VERSIONS}" | sort | tail -1)
om stage-product --product-name hub-tas-collector --product-version ${COLLECTOR_VERSION}

# Perform manual foundation attach to get required configuration for the Platform Services tile
ATTACH_FOUNDATION_RESPONSE=$(th -k foundation attach manual --name ${COLLECTOR_NAME} -o json)

# Parse the ATTACH_FOUNDATION_RESPONSE JSON structure
collector_id=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '."collector-id"')
foundation_id=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '."foundation-id"')
org_id=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '."org-id"')
ingestion_url=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '.ingestion_url')
oauth_client_id=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '."oauth-app-id"')
oauth_client_secret=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '."oauth-app-secret"')
cert_bundle=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '.caBundle')
foundation_name=$(echo ${ATTACH_FOUNDATION_RESPONSE} | jq -r '.foundationName')

# Generate the original config for the Platform Services tile
om staged-config -p hub-tas-collector > hub-tas-collector-original.yml

# Configure the Platform Services tile
om configure-product \
    --config hub-tas-collector-original.yml \
    --ops-file $CONFIG_DIR/${PRODUCT_SLUG}/${PRODUCT_VERSION}/hub-collector-ops.yml \
    --var az_name_list="${az_name_list}" \
    --var single_az="${single_az}" \
    --var environment_tag="${environment_tag}" \
    --var tpst_client_id="${TPST_CLIENT_ID}" \
    --var tpst_client_secret="${TPST_CLIENT_SECRET}" \
    --var collector_id="${collector_id}" \
    --var org_id="${org_id}" \
    --var foundation_id="${foundation_id}" \
    --var ingestion_url="${ingestion_url}" \
    --var oauth_client_id="${oauth_client_id}" \
    --var oauth_client_secret="${oauth_client_secret}" \
    --var collector_name="${COLLECTOR_NAME}" \
    --var cert_bundle="${cert_bundle}"

# Apply changes
retry om apply-changes -n hub-tas-collector

# Parse the certs required for ERT log collection config
opsman_root_ca=$(om certificate-authorities --format json | jq -r '.[0].cert_pem')
otel_agent_cert=$(om credentials --product-name hub-tas-collector --credential-reference .properties.collector_mtls --credential-field cert_pem)
otel_agent_key=$(om credentials --product-name hub-tas-collector --credential-reference .properties.collector_mtls --credential-field private_key_pem)
log_store_cert=$(om credentials --product-name hub-tas-collector --credential-reference .logs-store.logs_store_mtls --credential-field cert_pem)
log_store_key=$(om credentials --product-name hub-tas-collector --credential-reference .logs-store.logs_store_mtls --credential-field private_key_pem)

# Generate the original config for the ERT tile
om staged-config -p cf > cf-original.yml || true

# Add logging config to lab ERT ops file
cat $CONFIG_DIR/${PRODUCT_SLUG}/${PRODUCT_VERSION}/scripts/cf-ops.yml >> $CONFIG_DIR/general/cf-ops.yml

# Configure ERT with logging config
om configure-product --config cf-original.yml --ops-file $CONFIG_DIR/general/cf-ops.yml \
  --var opsman_root_ca="${opsman_root_ca}" \
  --var otel_agent_cert="${otel_agent_cert}" \
  --var otel_agent_key="${otel_agent_key}" \
  --var log_store_cert="${log_store_cert}" \
  --var log_store_key="${log_store_key}"

# Apply changes
retry om apply-changes -n cf -n hub-tas-collector

echo "Script completed successfully!" >&2
