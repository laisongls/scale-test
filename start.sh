#-------------------------------------------------------
# This script used to create spoke clusters on BMs of scale lab, 
# including create VMs, kind clusters, and to import the clusters.
# Prerquest: libvirt, vminit templet
#-------------------------------------------------------

#!/bin/bash

# Need to set
# Hub cluster info
hubclusterurl="api.slai-ocp46-aws.dev09.red-chesterfield.com:6443"
hubclusterpasswd="T8JSo-YhWpX-FrSXC-33vGr"

# Need to set
# Only 100 pulls per six hours without authentication
dockeruser=laisongls
dockerpasswd=Tang3zang

# 5 kind clusters on each vm
clusterrange="1..5"


function createVMs() {
# Install expect for interactive actions
echo "#Checking expect..."
if [ ! -e "/usr/bin/expect" ]
then
  /usr/bin/yum -y install expect >/dev/null
else
  echo "#expect has been installed."
fi

# Clean existed vm hosts file
if [ -f "vmhosts" ];
then
  rm -f vmhosts
fi

#-------------------------------------------------------
# Prepare VMs - need to set {range} for how many VMs will 
# be created on a BM, the number is used for VM hostname.
#-------------------------------------------------------
for t in {01..10}
do

# Clone vm
echo "#Clone vm from templet..."
virt-clone -o vminit -n vm$t -f /centos7/vm$t.qcow2
printf "\n"
echo "#Wait 20 sec for vm$t to start..."
virsh start vm$t
sleep 20

# Get vm ip
echo "#Setting up vm..."
vmmac=$(virsh dumpxml vm$t |grep 'mac address' |sed "s/'/ /g" |awk '{print $3}')

while [ -z "$(grep $vmmac /proc/net/arp |awk '{print $1}')" ]
do
  echo "#vm ip address does not exist, wait..."
  sleep 5
done

vmipaddr=$(grep $vmmac /proc/net/arp |awk '{print $1}')

echo "$t $vmipaddr" >> vmhosts

# Delete ssh known host if it exists
sed -i '/'"$vmipaddr"'/d' /root/.ssh/known_hosts

# Set to login vm without passwd
vmpasswd='root'
/usr/bin/expect <<-EOFNonPasswd
spawn ssh-copy-id -i /root/.ssh/id_rsa.pub root@$vmipaddr
set timeout 10;
expect {
        yes/no {send yes\n;exp_continue};
        password: {send $vmpasswd\n};
}
set timeout 10;
expect eof
EOFNonPasswd

# Set vm hostname
ssh $vmipaddr "hostnamectl set-hostname vm$t"

done
printf "\n"
echo "#All VMs are ready."
}


#-------------------------------------------------------
# Create & register & import kind clusters
#-------------------------------------------------------
function createManagedClusters() {
echo "#Setting up managed clusters on the VMs..."
cat vmhosts|while read line
do

vmid=$(echo $line |awk '{print $1}')
vmip=$(echo $line |awk '{print $2}')

# Kind cluster creation script
cat > tmp-01-create-cluster.sh <<EOFKindCreation
#!/bin/bash
# Create kind cluster config yaml
cat > kind.yaml <<EOFKindConfig
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "$vmip"
#nodes:
#- role: control-plane
#- role: worker
EOFKindConfig

# Login docker to increase pull limits
docker login -u $dockeruser -p $dockerpasswd

# Create kind clusters on vm
for i in {$clusterrange}
do

kind create cluster --name vm$vmid-cluster\$i  --config ./kind.yaml
echo "#Cluster vm$vmid-cluster\$i has been created."
printf "\n"

done
EOFKindCreation

# Cluster registration script
cat > tmp-02-register-cluster.sh <<EOFClusterRegistry
#!/bin/bash
# Login hub cluster
oc login -u kubeadmin -p $hubclusterpasswd --server=https://$hubclusterurl --insecure-skip-tls-verify=true
for i in {$clusterrange} 
do 

# Create namespace to avoid error of registry cluster in bach
kubectl create ns vm$vmid-cluster\$i

# Apply registration and klusterlet addon config
cat <<EOFClusterRegistryYAML | kubectl apply -f - 
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  labels:
    cloud: ACM
    vendor: ACMQE
    name: vm$vmid-cluster\$i
    environment: 'qa'
    team: 'test'
  name: vm$vmid-cluster\$i
spec:
  hubAcceptsClient: true
---
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: vm$vmid-cluster\$i
  namespace: vm$vmid-cluster\$i
spec:
  clusterName: vm$vmid-cluster\$i
  clusterNamespace: vm$vmid-cluster\$i
  clusterLabels:
    cloud: ACM
    vendor: ACMQE
  applicationManager:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  certPolicyController:
    enabled: true
  iamPolicyController:
    enabled: true
  version: 2.1.0
EOFClusterRegistryYAML

echo "#Cluster vm$vmid-cluster\$i has been registried."
printf "\n"

done
EOFClusterRegistry

# Cluster import script
cat > tmp-03-import-cluster.sh <<EOFClusterImport
#!/bin/bash
for i in {$clusterrange}
do

# Get import secret from hub
kubectl config use-context default/$(echo $hubclusterurl |sed s/\\./-/g)/kube:admin
kubectl get secret vm$vmid-cluster\$i-import -n vm$vmid-cluster\$i -o json > temp-import-secret.json

# Shift to kind cluster
kubectl config use-context kind-vm$vmid-cluster\$i

# Convert & apply klusterlet crd
cat temp-import-secret.json | shyaml get-value 'data'.'crds\.yaml' |base64 -d > managed-cluster-klusterlet-crd.yaml
kubectl apply -f managed-cluster-klusterlet-crd.yaml

# Convert & apply managed cluster import
cat temp-import-secret.json | shyaml get-value 'data'.'import\.yaml' |base64 -d > managed-cluster-import.yaml
kubectl apply -f managed-cluster-import.yaml

echo "#Cluster vm$vmid-cluster\$i has been created."
printf "\n"

done
EOFClusterImport


# Create kind clusters on VMs
echo "#########################################"
echo "#Create kind clusters on vm$vmid..."
printf "\n"
chmod 755 tmp-01-create-cluster.sh
scp tmp-01-create-cluster.sh $vmip:/root/01-create-cluster.sh
ssh $vmip "/root/01-create-cluster.sh" < /dev/null

# Register clusters to hub
echo "#########################################"
echo "#Register managed clusters for vm$vmid..."
printf "\n"
chmod 755 tmp-02-register-cluster.sh
scp tmp-02-register-cluster.sh $vmip:/root/02-register-cluster.sh
ssh $vmip "/root/02-register-cluster.sh" < /dev/null

# Import managed clusters
echo "#########################################"
echo "#Import managed clusters for vm$vmid..."
printf "\n"
chmod 755 tmp-03-import-cluster.sh
scp tmp-03-import-cluster.sh $vmip:/root/03-import-cluster.sh
ssh $vmip "/root/03-import-cluster.sh" < /dev/null

# Clean the temp scripts
ssh $vmip "rm -f /root/01-create-cluster.sh" < /dev/null
ssh $vmip "rm -f /root/02-register-cluster.sh" < /dev/null
ssh $vmip "rm -f /root/03-import-cluster.sh" < /dev/null
ssh $vmip "rm -f /root/kind.yaml" < /dev/null
ssh $vmip "rm -f /root/temp-import-secret.json" < /dev/null
ssh $vmip "rm -f /root/managed-cluster-klusterlet-crd.yaml" < /dev/null
ssh $vmip "rm -f /root/managed-cluster-import.yaml" < /dev/null

rm -f tmp-01-create-cluster.sh
rm -f tmp-02-register-cluster.sh
rm -f tmp-03-import-cluster.sh

done
}

#------------- main -------------
createVMs
#createManagedClusters

