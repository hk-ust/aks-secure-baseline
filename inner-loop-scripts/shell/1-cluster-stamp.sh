#!/usr/bin/env bash
set -e

# This script might take about 10 minutes

# Cluster Parameters.
LOCATION=$1
RGNAMECLUSTER=$2
RGNAMESPOKES=$3
TENANT_ID=$4
MAIN_SUBSCRIPTION=$5
TARGET_VNET_RESOURCE_ID=$6
K8S_RBAC_AAD_ADMIN_GROUP_OBJECTID=$7
K8S_RBAC_AAD_PROFILE_TENANTID=$8

# Used for services that support native geo-redundancy (Azure Container Registry)
# Ideally should be the paired region of $LOCATION
GEOREDUNDANCY_LOCATION=southeastasia

APPGW_APP_URL=bicycle.contoso.com

#az login
az account set -s $MAIN_SUBSCRIPTION

echo ""
echo "# Deploying AKS Cluster"
echo ""

# App Gateway Certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -out appgw.crt \
        -keyout appgw.key \
        -subj "/CN=bicycle.contoso.com/O=Contoso Bicycle" \
        -addext "subjectAltName = DNS:bicycle.contoso.com" -addext "keyUsage = digitalSignature"  -addext "extendedKeyUsage = serverAuth"
openssl pkcs12 -export -out appgw.pfx -in appgw.crt -inkey appgw.key -passout pass:
APP_GATEWAY_LISTENER_CERTIFICATE=$(cat appgw.pfx | base64 | tr -d '\n')

# AKS Ingress Controller Certificate
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -out traefik-ingress-internal-aks-ingress-tls.crt \
        -keyout traefik-ingress-internal-aks-ingress-tls.key \
        -subj "/CN=*.aks-ingress.contoso.com/O=Contoso Aks Ingress"
AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64=$(cat traefik-ingress-internal-aks-ingress-tls.crt | base64 | tr -d '\n')

# AKS Cluster Creation. Advance Networking. AAD identity integration. This might take about 10 minutes
# Note: By default, this deployment will allow unrestricted access to your cluster's API Server.
#   You should limit access to the API Server to a set of well-known IP addresses (i.,e. your hub firewall IP, bastion subnet, build agents, or any other networks you'll administer the cluster from),
#   and can do so by adding a `clusterAuthorizedIPRanges=['range1', 'range2', 'AzureFirewallIP/32']` parameter below.
az deployment group create --resource-group "${RGNAMECLUSTER}" --template-file "../../cluster-stamp.json" --name "cluster-0001" --parameters \
               location=$LOCATION \
               geoRedundancyLocation=$GEOREDUNDANCY_LOCATION \
               targetVnetResourceId=$TARGET_VNET_RESOURCE_ID \
               clusterAdminAadGroupObjectId=$K8S_RBAC_AAD_ADMIN_GROUP_OBJECTID \
               a0008NamespaceReaderAadGroupObjectId=86735eb4-9c41-48e3-a256-4eeec9481372 \
               k8sControlPlaneAuthorizationTenantId=$K8S_RBAC_AAD_PROFILE_TENANTID \
               appGatewayListenerCertificate=$APP_GATEWAY_LISTENER_CERTIFICATE \
               aksIngressControllerCertificate=$AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64

AKS_CLUSTER_NAME=$(az deployment group show -g $RGNAMECLUSTER -n cluster-0001 --query properties.outputs.aksClusterName.value -o tsv)
TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID=$(az deployment group show -g $RGNAMECLUSTER -n cluster-0001 --query properties.outputs.aksIngressControllerPodManagedIdentityResourceId.value -o tsv)
TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID=$(az deployment group show -g $RGNAMECLUSTER -n cluster-0001 --query properties.outputs.aksIngressControllerPodManagedIdentityClientId.value -o tsv)
KEYVAULT_NAME=$(az deployment group show -g $RGNAMECLUSTER -n cluster-0001 --query properties.outputs.keyVaultName.value -o tsv)
APPGW_PUBLIC_IP=$(az deployment group show -g $RGNAMESPOKES -n spoke-0001 --query properties.outputs.appGwPublicIpAddress.value -o tsv)

TEMP_ROLEASSIGNMENT_TO_UPLOAD_CERT=$(az role assignment create --role a4417e6f-fecd-4de8-b567-7b0420556985 --assignee-principal-type user --assignee-object-id $(az ad signed-in-user show --query 'objectId' -o tsv) --scope $(az keyvault show --name $KEYVAULT_NAME --query 'id' -o tsv) --query 'id' -o tsv)
CURRENT_IP_ADDRESS=$(curl -s https://ifconfig.io)
az keyvault network-rule add -n $KEYVAULT_NAME --ip-address ${CURRENT_IP_ADDRESS}

cat traefik-ingress-internal-aks-ingress-tls.crt traefik-ingress-internal-aks-ingress-tls.key > traefik-ingress-internal-aks-ingress-tls.pem

cat <<EOF

It takes time to propagate the role assignment. Execute below in new shell session:

# az keyvault certificate import --vault-name $KEYVAULT_NAME -f traefik-ingress-internal-aks-ingress-tls.pem -n traefik-ingress-internal-aks-ingress-tls

After success, remove Azure Key Vault import certificates permissions and network access for current user

# az keyvault network-rule remove -n $KEYVAULT_NAME --ip-address "${CURRENT_IP_ADDRESS}/32"
# az role assignment delete --ids $TEMP_ROLEASSIGNMENT_TO_UPLOAD_CERT

EOF

az aks get-credentials -n ${AKS_CLUSTER_NAME} -g ${RGNAMECLUSTER} --admin --overwrite-existing
kubectl create namespace cluster-baseline-settings
kubectl apply -f ../../cluster-manifests/cluster-baseline-settings/flux.yaml
kubectl wait --namespace cluster-baseline-settings --for=condition=ready pod --selector=app.kubernetes.io/name=flux --timeout=300s

ACR_NAME=$(az deployment group show -g $RGNAMECLUSTER -n cluster-0001 --query properties.outputs.containerRegistryName.value -o tsv)
# Import ingress controller image hosted in public container registries
az acr import --source docker.io/library/traefik:v2.4.8 -n $ACR_NAME

echo ""
echo "# Creating AAD Groups and users for the created cluster"
echo ""

# unset errexit as per https://github.com/mspnp/aks-secure-baseline/issues/69
set +e
echo $'Ensure Flux has created the following namespace and then press Ctrl-C'
kubectl get ns a0008 --watch


cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: podmi-ingress-controller-identity
  namespace: a0008
spec:
  type: 0
  resourceID: $TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID
  clientID: $TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID
---
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentityBinding
metadata:
  name: podmi-ingress-controller-binding
  namespace: a0008
spec:
  azureIdentity: podmi-ingress-controller-identity
  selector: podmi-ingress-controller
EOF

cat <<EOF | kubectl apply -f -
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: aks-ingress-tls-secret-csi-akv
  namespace: a0008
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"
    keyvaultName: "${KEYVAULT_NAME}"
    objects:  |
      array:
        - |
          objectName: traefik-ingress-internal-aks-ingress-tls
          objectAlias: tls.crt
          objectType: cert
        - |
          objectName: traefik-ingress-internal-aks-ingress-tls
          objectAlias: tls.key
          objectType: secret
    tenantId: "${TENANT_ID}"
EOF


kubectl apply -f ../../workload/traefik.yaml
kubectl apply -f ../../workload/aspnetapp.yaml

echo 'the ASPNET Core webapp sample is all setup. Wait until is ready to process requests running'
kubectl wait --namespace a0008 \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=aspnetapp \
  --timeout=90s
echo 'you must see the EXTERNAL-IP 10.26.20.4, please wait till it is ready. It takes a some minutes, then cntr+c'
kubectl get svc -n traefik --watch  -n a0008

rm appgw.crt appgw.key appgw.pfx

cat << EOF

NEXT STEPS
---- -----

1) Map the Azure Application Gateway public ip address to the application domain names. To do that, please open your hosts file (C:\windows\system32\drivers\etc\hosts or /etc/hosts) and add the following record in local host file:
    ${APPGW_PUBLIC_IP} ${APPGW_APP_URL}

2) In your browser navigate the site anyway (A warning will be present)
 https://${APPGW_APP_URL}

# Clean up resources. Execute:

deleteResourceGroups.sh

EOF
