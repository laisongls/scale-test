### Prepare KVM cloud image
```
mkdir /centos7
cd /centos7
curl -O http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2.xz
xz -d CentOS-7-x86_64-GenericCloud.qcow2.xz
cp CentOS-7-x86_64-GenericCloud.qcow2 vminit.qcow2
```

### Pre-settings for root passwd and disk size
```
virt-customize -a vminit.qcow2 --root-password password:root
qemu-img resize vminit.qcow2 +36G
```

### Start VM
```
virt-install --os-variant centos7.0 \
--name vminit \
--memory 16384 \
--vcpus 4 \
--network bridge=virbr0 \
--disk vminit.qcow2,device=disk,bus=virtio \
--graphics none \
--import
```

### Login to VM then resize the mount point / 
```
virsh console vminit # user/passwd: root/root
df -h
fdisk -l
fdisk /dev/vda
    -> d
    -> n
    -> default
    -> default
    -> default
    -> default
    -> w
reboot
xfs_growfs /
df -h
```

### Copy automation scripts, oc, kubectl and kind into the VM path

### Install docker on VM
```
curl  https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
yum install docker-ce -y
systemctl start docker
systemctl enable docker
```

### Install shyaml to make shell to read yaml on VM
```
curl -O https://bootstrap.pypa.io/get-pip.py
python get-pip.py
pip2 install shyaml
```

### Clone the VM as a templet
```
virsh shutdown vminit
virt-clone -o vminit -n vm16 -f /centos7/vm16.qcow2
```

