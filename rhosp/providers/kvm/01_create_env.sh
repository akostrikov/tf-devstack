#!/bin/bash -ex

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run by root"
   exit 1
fi


# VBMC base port for IPMI management
VBMC_PORT_BASE=16000

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"


OS_MEM=${OS_MEM:-8192}
CTRL_MEM=${CTRL_MEM:-8192}
COMP_MEM=${COMP_MEM:-8192}

vm_disk_size=${vm_disk_size:-30G}
net_driver=${net_driver:-virtio}

source "/home/$SUDO_USER/rhosp-environment.sh"
source "$my_dir/virsh_functions"

image_customize ${BASE_IMAGE} undercloud $ssh_public_key

# check if environment is present
assert_env_exists $undercloud_vmname

# define MAC's
undercloud_mgmt_mac=${undercloud_mgmt_mac:-00:16:00:00:08:02}
undercloud_prov_mac=${undercloud_prov_mac:-00:16:00:00:08:03}

# create networks and setup DHCP rules
create_network_dhcp $NET_NAME_MGMT $mgmt_subnet $BRIDGE_NAME_MGMT
update_network_dhcp $NET_NAME_MGMT $undercloud_vmname $undercloud_mgmt_mac $mgmt_ip

create_network_dhcp $NET_NAME_PROV $prov_subnet $BRIDGE_NAME_PROV 'no' 'no_forward'

# create pool
create_pool $poolname
pool_path=$(get_pool_path $poolname)

function create_root_volume() {
  local name=$1
  create_volume $name $poolname $vm_disk_size
}

# use names
function define_overcloud_vms() {
  local name=$1
  local mem=$2
  local vbmc_port=$3
  local vcpu=${4:-2}
  local vol_name=$name
  create_root_volume $vol_name
  local vm_name="$vol_name"
  define_machine $vm_name $vcpu $mem rhel7 $NET_NAME_PROV "${pool_path}/${vol_name}.qcow2"
  start_vbmc $vbmc_port $vm_name $mgmt_gateway $IPMI_USER $IPMI_PASSWORD
}

function define_overcloud_vms_without_vbmc() {
  local name=$1
  local mem=$2
  local mac=$3
  local ip=$4
  local vcpu=${5:-2}
  local vol_name=$name
  #create_root_volume $vol_name
  local vm_name="$vol_name"
  image_customize ${BASE_IMAGE} $vm_name $ssh_public_key
  cp -p $BASE_IMAGE $pool_path/$vol_name.qcow2
  update_network_dhcp $NET_NAME_PROV $vm_name $mac $ip
  define_machine $vm_name $vcpu $mem rhel7 $NET_NAME_PROV/$mac "${pool_path}/${vol_name}.qcow2"
}


# just define overcloud machines
if [[ "$USE_PREDEPLOYED_NODES" == false ]]; then
vbmc_port=$VBMC_PORT_BASE
  define_overcloud_vms $overcloud_cont_instance $OS_MEM $vbmc_port 4
  (( vbmc_port+=1 ))
  define_overcloud_vms $overcloud_compute_instance $COMP_MEM $vbmc_port 4
  (( vbmc_port+=1 ))
  define_overcloud_vms $overcloud_ctrlcont_instance $CTRL_MEM $vbmc_port 4
  (( vbmc_port+=1 ))
else
  define_overcloud_vms_without_vbmc $overcloud_cont_instance $OS_MEM $overcloud_cont_prov_mac $overcloud_cont_prov_ip 4
  define_overcloud_vms_without_vbmc $overcloud_compute_instance $COMP_MEM $overcloud_compute_prov_mac $overcloud_compute_prov_ip 4
  define_overcloud_vms_without_vbmc $overcloud_ctrlcont_instance $CTRL_MEM $overcloud_ctrlcont_prov_mac $overcloud_ctrlcont_prov_ip 4
fi

# copy image for undercloud and resize them
cp -p $BASE_IMAGE $pool_path/$undercloud_vm_volume

#check that nbd kernel module is loaded
if ! lsmod |grep '^nbd ' ; then
  modprobe nbd max_part=8
fi

function _start_vm() {
  local name=$1
  local image=$2
  local mgmt_mac=$3
  local prov_mac=$4
  local ram=${5:-16384}

  # define and start machine
  virt-install --name=$name \
    --ram=$ram \
    --vcpus=2,cores=2 \
    --cpu host \
    --memorybacking hugepages=on \
    --os-type=linux \
    --os-variant=rhel7 \
    --virt-type=kvm \
    --disk "path=$image",size=40,cache=writeback,bus=virtio \
    --boot hd \
    --noautoconsole \
    --network network=$NET_NAME_MGMT,model=$net_driver,mac=$mgmt_mac \
    --network network=$NET_NAME_PROV,model=$net_driver,mac=$prov_mac \
    --graphics vnc,listen=0.0.0.0
}

_start_vm "$undercloud_vmname" "$pool_path/$undercloud_vm_volume" \
  $undercloud_mgmt_mac $undercloud_prov_mac


