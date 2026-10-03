#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: bash deploy.sh --confirm-create [--replace-unattached-public-ip]

Creates the Azure P2S VPN lab resources. The VPN gateway is billable while it
exists. Configure the deployment with these optional environment variables:
  AZURE_SUBSCRIPTION_ID, P2S_RESOURCE_GROUP, P2S_LOCATION
  P2S_VNET_CIDR, P2S_VM_SUBNET_CIDR, P2S_GATEWAY_SUBNET_CIDR
  P2S_CLIENT_POOL, P2S_VM_SIZE, P2S_SSH_KEY_PATH

Use --replace-unattached-public-ip only when upgrading this lab's old,
unattached gateway IP to the required zone-redundant IP.
EOF
}

confirmed=false
replace_unattached_public_ip=false
while (($#)); do
  case "$1" in
    --confirm-create) confirmed=true ;;
    --replace-unattached-public-ip) replace_unattached_public_ip=true ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$confirmed" != true ]]; then
  printf 'Refusing to create billable Azure resources without --confirm-create.\n' >&2
  usage >&2
  exit 2
fi

command -v az >/dev/null || { printf 'Azure CLI (az) is required.\n' >&2; exit 1; }
command -v ssh-keygen >/dev/null || { printf 'ssh-keygen is required.\n' >&2; exit 1; }
az account show >/dev/null 2>&1 || {
  printf 'Sign in first with: az login\n' >&2
  exit 1
}

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RG="${P2S_RESOURCE_GROUP:-rg-p2s-lab}"
LOCATION="${P2S_LOCATION:-centralindia}"
VNET="${P2S_VNET_NAME:-vnet-p2s}"
VM_SUBNET="${P2S_VM_SUBNET_NAME:-vm-subnet}"
GATEWAY="${P2S_GATEWAY_NAME:-vpngw-p2s}"
VM="${P2S_VM_NAME:-vm-p2s}"
NIC="${P2S_NIC_NAME:-nic-p2s-vm}"
NSG="${P2S_NSG_NAME:-nsg-p2s-vm}"
PIP="${P2S_PUBLIC_IP_NAME:-pip-p2s-gateway}"
VNET_CIDR="${P2S_VNET_CIDR:-10.0.0.0/16}"
VM_CIDR="${P2S_VM_SUBNET_CIDR:-10.0.2.0/24}"
GATEWAY_CIDR="${P2S_GATEWAY_SUBNET_CIDR:-10.0.1.0/27}"
VPN_POOL="${P2S_CLIENT_POOL:-172.16.0.0/24}"
VM_IP="${P2S_VM_PRIVATE_IP:-10.0.2.4}"
VM_SIZE="${P2S_VM_SIZE:-Standard_B2s_v2}"
SSH_KEY_PATH="${P2S_SSH_KEY_PATH:-$HOME/.ssh/p2s_lab_key}"
ADMIN_USER="${P2S_ADMIN_USER:-azureuser}"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi

TENANT_ID=$(az account show --query tenantId -o tsv)
AAD_TENANT="https://login.microsoftonline.com/$TENANT_ID"
AAD_ISSUER="https://sts.windows.net/$TENANT_ID/"
AAD_AUDIENCE="c632b3df-fb67-4d84-bdcf-b95ad541b5c8"

resource_exists() {
  local resource_id
  resource_id=$("$@" --query id -o tsv 2>/dev/null) && [[ -n "$resource_id" ]]
}

printf 'Creating lab resources in %s (%s)...\n' "$RG" "$LOCATION"
az group create --name "$RG" --location "$LOCATION" --output none

if ! resource_exists az network vnet show --resource-group "$RG" --name "$VNET"; then
  az network vnet create \
    --resource-group "$RG" --name "$VNET" --location "$LOCATION" \
    --address-prefixes "$VNET_CIDR" \
    --subnet-name "$VM_SUBNET" --subnet-prefixes "$VM_CIDR" --output none
fi

if ! resource_exists az network vnet subnet show \
  --resource-group "$RG" --vnet-name "$VNET" --name GatewaySubnet; then
  az network vnet subnet create \
    --resource-group "$RG" --vnet-name "$VNET" \
    --name GatewaySubnet --address-prefixes "$GATEWAY_CIDR" --output none
fi

if ! resource_exists az network nsg show --resource-group "$RG" --name "$NSG"; then
  az network nsg create --resource-group "$RG" --name "$NSG" \
    --location "$LOCATION" --output none
fi

for rule in Allow-VPN-SSH Allow-VPN-HTTP; do
  if ! resource_exists az network nsg rule show \
    --resource-group "$RG" --nsg-name "$NSG" --name "$rule"; then
    if [[ "$rule" == Allow-VPN-SSH ]]; then
      port=22
      priority=100
    else
      port=80
      priority=110
    fi
    az network nsg rule create \
      --resource-group "$RG" --nsg-name "$NSG" --name "$rule" \
      --priority "$priority" --direction Inbound --access Allow --protocol Tcp \
      --source-address-prefixes "$VPN_POOL" \
      --destination-address-prefixes "$VM_IP" \
      --destination-port-ranges "$port" --output none
  fi
done

mkdir -p "$(dirname "$SSH_KEY_PATH")"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N ''
fi

if ! resource_exists az network nic show --resource-group "$RG" --name "$NIC"; then
  az network nic create \
    --resource-group "$RG" --name "$NIC" --location "$LOCATION" \
    --vnet-name "$VNET" --subnet "$VM_SUBNET" \
    --network-security-group "$NSG" \
    --private-ip-address "$VM_IP" --output none
fi

if ! resource_exists az vm show --resource-group "$RG" --name "$VM"; then
  az vm create \
    --resource-group "$RG" --name "$VM" --location "$LOCATION" \
    --image Ubuntu2404 --size "$VM_SIZE" --admin-username "$ADMIN_USER" \
    --ssh-key-values "${SSH_KEY_PATH}.pub" --nics "$NIC" --output none
fi

if resource_exists az network public-ip show --resource-group "$RG" --name "$PIP"; then
  PIP_ZONES=$(az network public-ip show \
    --resource-group "$RG" --name "$PIP" --query zones -o tsv | tr '\t\n' ',')
  PIP_ZONES="${PIP_ZONES%,}"
  if [[ "$PIP_ZONES" != "1,2,3" ]]; then
    PIP_ATTACHMENT=$(az network public-ip show \
      --resource-group "$RG" --name "$PIP" --query ipConfiguration.id -o tsv)
    if [[ -n "$PIP_ATTACHMENT" ]]; then
      printf 'Public IP %s is attached and is not zone redundant; refusing to replace it.\n' "$PIP" >&2
      exit 1
    fi
    if [[ "$replace_unattached_public_ip" != true ]]; then
      printf 'Public IP %s is unattached and has zones "%s".\n' "$PIP" "$PIP_ZONES" >&2
      printf 'Rerun with --replace-unattached-public-ip to replace it with a zone-redundant IP.\n' >&2
      exit 1
    fi
    az network public-ip delete --resource-group "$RG" --name "$PIP"
    az network public-ip create \
      --resource-group "$RG" --name "$PIP" --location "$LOCATION" \
      --sku Standard --allocation-method Static --zone 1 2 3 --output none
  fi
else
  az network public-ip create \
    --resource-group "$RG" --name "$PIP" --location "$LOCATION" \
    --sku Standard --allocation-method Static --zone 1 2 3 --output none
fi

if ! resource_exists az network vnet-gateway show \
  --resource-group "$RG" --name "$GATEWAY"; then
  az network vnet-gateway create \
    --resource-group "$RG" --name "$GATEWAY" --location "$LOCATION" \
    --vnet "$VNET" --public-ip-addresses "$PIP" \
    --gateway-type Vpn --vpn-type RouteBased --sku VpnGw1AZ --output none
fi

az network vnet-gateway update \
  --resource-group "$RG" --name "$GATEWAY" \
  --address-prefixes "$VPN_POOL" --client-protocol OpenVPN \
  --vpn-auth-type AAD --aad-tenant "$AAD_TENANT" \
  --aad-audience "$AAD_AUDIENCE" --aad-issuer "$AAD_ISSUER" --output none

printf '\nDeployment commands completed. Verify gateway provisioning before continuing.\n'
printf 'Download the Azure VPN Client profile from the portal for %s.\n' "$GATEWAY"
printf 'SSH key: %s\n' "$SSH_KEY_PATH"
az vm show --resource-group "$RG" --name "$VM" -d \
  --query '{Name:name,Power:powerState,PrivateIP:privateIps,PublicIP:publicIps}' -o table