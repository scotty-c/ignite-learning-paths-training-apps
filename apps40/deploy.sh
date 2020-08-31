#!/bin/bash
set -e

# Credentials
azureClientID=$CLIENT_ID
azureClientSecret=$SECRET
sqlServerUser=sqladmin
sqlServePassword=Password2020!

# Azure and container image location
azureResourceGroup=$RESOURCE_GROUP_NAME
containerRegistry=neilpeterson
containerVersion=v2

# Tailwind deployment
tailwindInfrastructure=deployment.json
tailwindCharts=TailwindTraders-Backend/Deploy/helm
tailwindChartValuesScript=TailwindTraders-Backend/Deploy/powershell/Generate-Config.ps1
tailwindChartValues=/values.yaml
tailwindWebImages=TailwindTraders-Backend/Deploy/tt-images
tailwindServiceAccount=TailwindTraders-Backend/Deploy/helm/ttsa.yaml

# Print out tail command
printf "\n*** To tail logs, run this command... ***\n"
echo "*************** Container logs ***************"
echo "az container logs --name bootstrap-container --resource-group $azureResourceGroup --follow"
echo "*************** Connection Information ***************"

# Get backend code
printf "\n*** Cloning Tailwind code repository... ***\n"

# Clone Tailwind backend and checkout known stable tag
git clone https://github.com/microsoft/TailwindTraders-Backend.git
#git -C TailwindTraders-Backend checkout ed86d5f

# Deploy network infrastructure
printf "\n*** Deploying networking resources ***\n"

# create the vnet
az network vnet create \
    --resource-group $azureResourceGroup \
    --name k8sVNet \
    --address-prefixes 10.0.0.0/8 \
    --subnet-name k8sSubnet \
    --subnet-prefix 10.240.0.0/16

# Create virtual node subnet
az network vnet subnet create \
    --resource-group $azureResourceGroup  \
    --vnet-name k8sVNet \
    --name VNSubnet  \
    --address-prefix 10.241.0.0/16


# Deploy backend infrastructure
printf "\n*** Deploying resources: this will take a few minutes... ***\n"
vnetID=$(az network vnet subnet show --resource-group $azureResourceGroup --vnet-name k8sVNet --name k8sSubnet --query id -o tsv)
az group deployment create -g $azureResourceGroup --template-file $tailwindInfrastructure \
  --parameters servicePrincipalId=$azureClientID servicePrincipalSecret=$azureClientSecret \
  sqlServerAdministratorLogin=$sqlServerUser sqlServerAdministratorLoginPassword=$sqlServePassword \
  aksVersion=1.18.4 pgversion=10 vnetSubnetID=$vnetID

# # Application Insights (using preview extension)
az extension add -n application-insights
instrumentationKey=$(az monitor app-insights component show --app tt-app-insights --resource-group $azureResourceGroup --query instrumentationKey -o tsv)
echo $instrumentationKey


# Create postgres DB, Disable SSL, and set Firewall
printf "\n*** Create stockdb Postgres database... ***\n"

POSTGRES=$(az postgres server list --resource-group $azureResourceGroup --query [0].name -o tsv)
az postgres db create -g $azureResourceGroup -s $POSTGRES -n stockdb
az postgres server update --resource-group $azureResourceGroup --name $POSTGRES --ssl-enforcement Disabled
az postgres server firewall-rule create --resource-group $azureResourceGroup --server-name $POSTGRES --name AllowAllAzureIps --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0

# Install Helm on Kubernetes cluster
#printf "\n*** Installing Tiller on Kubernets cluster... ***\n"

AKS_CLUSTER=$(az aks list --resource-group $azureResourceGroup --query [0].name -o tsv)
az aks get-credentials --name $AKS_CLUSTER --resource-group $azureResourceGroup --admin
#kubectl apply -f https://raw.githubusercontent.com/Azure/helm-charts/master/docs/prerequisities/helm-rbac-config.yaml
#helm init --wait --service-account tiller

printf "\n*** Installing virtual node on Kubernets cluster... ***\n"
# Deploy virtual node 
az aks enable-addons \
    --resource-group $azureResourceGroup  \
    --name $AKS_CLUSTER \
    --addons virtual-node \
    --subnet-name VNSubnet

# Create Kubernetes Service Account
printf "\n*** Create Helm service account in Kubernetes... ***\n"
nameSpace=twt
kubectl create namespace $nameSpace
kubectl label namespace/$nameSpace purpose=prod-app
#kubectl apply -f $tailwindServiceAccount

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
imagePullSecrets:
- name: acr-auth
metadata:
  name: ttsa
  namespace: $nameSpace
EOF


# Create Helm values file
printf "\n*** Create Helm values file... ***\n"

pwsh -File $tailwindChartValuesScript -resourceGroup $azureResourceGroup -outputFile $tailwindChartValues

# Deploy application to Kubernetes
printf "\n***Deplpying applications to Kubernetes.***\n"

INGRESS=$(az aks show -n $AKS_CLUSTER -g $azureResourceGroup --query addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName -o tsv)
pictures=$(az storage account list -g $azureResourceGroup --query [0].primaryEndpoints.blob -o tsv)

# App Insights Versions
cat $tailwindChartValues
sed -i 's/\(.*id:.*\)/id: $instrumentationKey/g' $tailwindChartValues
helm install my-tt-login  $tailwindCharts/login-api -f $tailwindChartValues  --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/login.api --set image.tag=$containerVersion --set inf.storage.profileimages=${pictures}profiles-list
helm install my-tt-product $tailwindCharts/products-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/product.api --set image.tag=$containerVersion --set inf.storage.productimages=${pictures}product-list --set inf.storage.productdetailimages=${pictures}product-detail
helm install my-tt-coupon $tailwindCharts/coupons-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/coupon.api --set image.tag=$containerVersion --set inf.storage.couponimage=${pictures}coupon-list
helm install my-tt-profile $tailwindCharts/profiles-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/profile.api --set image.tag=$containerVersion --set inf.storage.profileimages=${pictures}profiles-list 
helm install my-tt-popular-product $tailwindCharts/popular-products-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/popular-product.api --set image.tag=$containerVersion --set initImage.repository=$containerRegistry/popular-product-seed.api --set initImage.tag=latest --set inf.storage.productimages=${pictures}product-list
helm install my-tt-stock $tailwindCharts/stock-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/stock.api --set image.tag=$containerVersion
helm install my-tt-image-classifier $tailwindCharts/image-classifier-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/image-classifier.api --set image.tag=$containerVersion
helm install my-tt-cart $tailwindCharts/cart-api -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/cart.api --set image.tag=$containerVersion
helm install my-tt-mobilebff $tailwindCharts/mobilebff -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/mobileapigw --set image.tag=$containerVersion --set probes.readiness=null
helm install my-tt-webbff $tailwindCharts/webbff -f $tailwindChartValues --namespace=$nameSpace --set ingress.hosts={$INGRESS} --set image.repository=$containerRegistry/webapigw --set image.tag=$containerVersion $tailwindCharts/webbff

# Pulling from a stable fork of the tailwind website
git clone https://github.com/microsoft/TailwindTraders-Website.git
helm install --name web -f TailwindTraders-Website/Deploy/helm/gvalues.yaml --namespace=$nameSpace --set B2C.UseB2C=false --set ingress.protocol=http --set ingress.hosts={$INGRESS} --set az.productvisitsurl={$INGRESS}  --set image.repository=$containerRegistry/web --set image.tag=v1 TailwindTraders-Website/Deploy/helm/web/

# Copy website images to storage
printf "\n***Copying application images (graphics) to Azure storage.***\n"

STORAGE=$(az storage account list -g $azureResourceGroup -o table --query  [].name -o tsv)
BLOB_ENDPOINT=$(az storage account list -g $azureResourceGroup --query [].primaryEndpoints.blob -o tsv)
CONNECTION_STRING=$(az storage account show-connection-string -n $STORAGE -g $azureResourceGroup -o tsv)
az storage container create --name "coupon-list" --public-access blob --connection-string $CONNECTION_STRING
az storage container create --name "product-detail" --public-access blob --connection-string $CONNECTION_STRING
az storage container create --name "product-list" --public-access blob --connection-string $CONNECTION_STRING
az storage container create --name "profiles-list" --public-access blob --connection-string $CONNECTION_STRING
az storage blob upload-batch --destination $BLOB_ENDPOINT --destination coupon-list  --source $tailwindWebImages/coupon-list --account-name $STORAGE
az storage blob upload-batch --destination $BLOB_ENDPOINT --destination product-detail --source $tailwindWebImages/product-detail --account-name $STORAGE
az storage blob upload-batch --destination $BLOB_ENDPOINT --destination product-list --source $tailwindWebImages/product-list --account-name $STORAGE
az storage blob upload-batch --destination $BLOB_ENDPOINT --destination profiles-list --source $tailwindWebImages/profiles-list --account-name $STORAGE

#
printf "\n***Setting up sclaing backend componets.***\n"
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install kedacore/keda --namespace keda --name keda

printf "\n***Setting up cluster information frontend.***\n"
helm repo add clusterInfo https://lsantos.dev/apps40-scalingdemo-frontend/helm
helm repo update

helm upgrade --install --atomic visualization-frontend-$nameSpace \
--set env=$nameSpace \
--set image.tag=latest \
--set ingress.hostname=cluster-info.${INGRESS} \
--set environment.API_URL=http://visualization-api.${INGRESS} \
--namespace $nameSpace \
clusterInfo/visualization-frontend
  
helm upgrade --install --atomic visualization-backend-$nameSpace \
--set env=$nameSpace \
--set image.tag=latest \
--set ingress.hostname=visualization-api.${INGRESS} \
--namespace $nameSpace \
clusterInfo/visualization-backend 
  
helm upgrade --install aso https://github.com/Azure/azure-service-operator/raw/master/charts/azure-service-operator-0.1.0.tgz \
        --create-namespace \
        --namespace=azureoperator-system \
        --set azureSubscriptionID=$AZURE_SUBSCRIPTION_ID \
        --set azureTenantID=$AZURE_TENANT_ID \
        --set azureClientSecret=$AZURE_CLIENT_SECRET \
        --set image.repository="mcr.microsoft.com/k8s/azureserviceoperator:latest"


# Notes
echo "*************** Connection Information ***************"
echo "The Tailwind Traders Website can be accessed at:"
echo "http://$INGRESS"
echo ""
echo "Run the following to connect to the AKS cluster:"
echo "az aks get-credentials --name $AKS_CLUSTER --resource-group $azureResourceGroup --admin"
echo "******************************************************"
