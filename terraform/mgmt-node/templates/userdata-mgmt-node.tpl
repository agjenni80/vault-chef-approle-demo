#!/usr/bin/env bash
set -x
exec > >(tee /var/log/tf-user-data.log|logger -t user-data ) 2>&1

logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo "$DT $0: $1"
}

logger "Running"

##--------------------------------------------------------------------
## Variables

# Get Public IP address
PRIVATE_DNS=$(curl http://169.254.169.254/latest/meta-data/hostname)

echo $${PRIVATE_DNS}

# User setup
USER_NAME="vault"
USER_COMMENT="HashiCorp Vault user"
USER_GROUP="vault"
USER_HOME="/srv/vault"

# S3 Bucket With Enterprise Binaries
S3_BUCKET="${tpl_s3_bucket_name}"

# Vault
VAULT_ZIP="${tpl_vault_zip_file}"

# Chef
CHEF_SERVER_PACKAGE_URL="${tpl_chef_server_package_url}"
CHEF_DK_PACKAGE_URL="${tpl_chef_dk_package_url}"
CHEF_SERVER_URL="https://$${PRIVATE_DNS}"
CHEF_ADMIN="${tpl_chef_admin}"
CHEF_ADMIN_PASSWORD="${tpl_chef_admin_password}"
CHEF_ADMIN_PEM="$${CHEF_ADMIN}-private-key.pem"
CHEF_DEMO_ORG="${tpl_chef_org}"
CHEF_DEMO_PEM="$${CHEF_DEMO_ORG}-validator.pem"
CHEF_DEMO_APP_NAME="${tpl_chef_app_name}"

# Detect package management system.
YUM=$(which yum 2>/dev/null)
APT_GET=$(which apt-get 2>/dev/null)

##--------------------------------------------------------------------
## Install Base Prerequisites

logger "Installing jq"
sudo curl --silent -Lo /bin/jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
sudo chmod +x /bin/jq

logger "Setting timezone to UTC"
sudo timedatectl set-timezone UTC

if [[ ! -z $${YUM} ]]; then
  logger "RHEL/CentOS system detected"
  logger "Performing updates and installing prerequisites"
  sudo yum-config-manager --enable rhui-REGION-rhel-server-releases-optional
  sudo yum-config-manager --enable rhui-REGION-rhel-server-supplementary
  sudo yum-config-manager --enable rhui-REGION-rhel-server-extras
  sudo yum -y check-update
  sudo yum install -q -y wget unzip bind-utils ruby rubygems ntp
  sudo systemctl start ntpd.service
  sudo systemctl enable ntpd.service
elif [[ ! -z $${APT_GET} ]]; then
  logger "Debian/Ubuntu system detected"
  logger "Performing updates and installing prerequisites"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y wget unzip dnsutils ruby rubygems ntp
  sudo systemctl start ntp.service
  sudo systemctl enable ntp.service
  logger "Disable reverse dns lookup in SSH"
  sudo sh -c 'echo "\nUseDNS no" >> /etc/ssh/sshd_config'
  sudo service ssh restart
else
  logger "Prerequisites not installed due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Install AWS-Specific Prerequisites

if [[ ! -z $${YUM} ]]; then
  logger "RHEL/CentOS system detected"
  logger "Performing updates and installing prerequisites"
  curl --silent -O https://bootstrap.pypa.io/get-pip.py
  sudo python get-pip.py
  sudo pip install awscli
elif [[ ! -z $${APT_GET} ]]; then
  logger "Debian/Ubuntu system detected"
  logger "Performing updates and installing prerequisites"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y awscli
else
  logger "AWS Prerequisites not installed due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Configure Vault user

user_rhel() {
  # RHEL/CentOS user setup
  sudo /usr/sbin/groupadd --force --system $${USER_GROUP}

  if ! getent passwd $${USER_NAME} >/dev/null ; then
    sudo /usr/sbin/adduser \
      --system \
      --gid $${USER_GROUP} \
      --home $${USER_HOME} \
      --no-create-home \
      --comment "$${USER_COMMENT}" \
      --shell /bin/false \
      $${USER_NAME}  >/dev/null
  fi
}

user_ubuntu() {
  # UBUNTU user setup
  if ! getent group $${USER_GROUP} >/dev/null
  then
    sudo addgroup --system $${USER_GROUP} >/dev/null
  fi

  if ! getent passwd $${USER_NAME} >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup $${USER_GROUP} \
      --home $${USER_HOME} \
      --no-create-home \
      --gecos "$${USER_COMMENT}" \
      --shell /bin/false \
      $${USER_NAME}  >/dev/null
  fi
}

if [[ ! -z $${YUM} ]]; then
  logger "Setting up user $${USER_NAME} for RHEL/CentOS"
  user_rhel
elif [[ ! -z $${APT_GET} ]]; then
  logger "Setting up user $${USER_NAME} for Debian/Ubuntu"
  user_ubuntu
else
  logger "$${USER_NAME} user not created due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Install Vault

logger "Downloading Vault"
aws --region ${tpl_aws_region} s3 cp s3://$${S3_BUCKET}/$${VAULT_ZIP} /tmp/$${VAULT_ZIP}

logger "Installing Vault"
sudo unzip -o /tmp/$${VAULT_ZIP} -d /usr/local/bin/
sudo chmod 0755 /usr/local/bin/vault
sudo chown vault:vault /usr/local/bin/vault
sudo mkdir -pm 0755 /etc/vault.d
sudo mkdir -pm 0755 /etc/ssl/vault

# Dir for file storage backend
sudo mkdir -pm 0755 /opt/vault

logger "/usr/local/bin/vault --version: $(/usr/local/bin/vault --version)"

logger "Configuring Vault"
sudo tee /etc/vault.d/vault.hcl <<EOF
storage "file" {
  path = "/opt/vault"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
seal "awskms" {
  region = "${tpl_aws_region}"
  kms_key_id = "${tpl_kms_key}"
}
ui=true
EOF

sudo chown -R vault:vault /etc/vault.d /etc/ssl/vault /opt/vault
sudo chmod -R 0644 /etc/vault.d/*

sudo tee -a /etc/profile.d/vault.sh <<EOF
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
EOF

source /etc/profile.d/vault.sh

logger "Granting mlock syscall to vault binary"
sudo setcap cap_ipc_lock=+ep /usr/local/bin/vault

##--------------------------------------------------------------------
## Install Vault Systemd Service

# Description=Vault Agent
# Requires=network-online.target
# After=network-online.target

read -d '' VAULT_SERVICE <<EOF
[Unit]
Description=Vault Agent
[Service]
Restart=on-failure
PermissionsStartOnly=true
ExecStartPre=/sbin/setcap 'cap_ipc_lock=+ep' /usr/local/bin/vault
ExecStart=/usr/local/bin/vault server -config /etc/vault.d
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
User=vault
Group=vault
[Install]
WantedBy=multi-user.target
EOF

if [[ ! -z $${YUM} ]]; then
  SYSTEMD_DIR="/etc/systemd/system"
  logger "Installing systemd services for RHEL/CentOS"
  echo "$${VAULT_SERVICE}" | sudo tee $${SYSTEMD_DIR}/vault.service
  sudo chmod 0664 $${SYSTEMD_DIR}/vault*
elif [[ ! -z $${APT_GET} ]]; then
  SYSTEMD_DIR="/lib/systemd/system"
  logger "Installing systemd services for Debian/Ubuntu"
  echo "$${VAULT_SERVICE}" | sudo tee $${SYSTEMD_DIR}/vault.service
  sudo chmod 0664 $${SYSTEMD_DIR}/vault*
else
  logger "Service not installed due to OS detection failure"
  exit 1;
fi

sudo systemctl enable vault
sudo systemctl start vault

##--------------------------------------------------------------------
## Vault Init, Configure Policies & Backends



##--------------------------------------------------------------------
## Install Chef Server & Chef DK

# Download Chef packages
sudo curl -o /tmp/chef-server-core.deb $${CHEF_SERVER_PACKAGE_URL}
sudo curl -o /tmp/chefdk.deb $${CHEF_DK_PACKAGE_URL}

# Install Chef packages
sudo dpkg -i /tmp/chef-server-core.deb
sudo dpkg -i /tmp/chefdk.deb

# Configure Chef Server (need to do this after installing Chef Server package)
sudo chef-server-ctl reconfigure

# Create an admin user and demo org
sudo chef-server-ctl user-create $${CHEF_ADMIN} demo admin $${CHEF_ADMIN}@example.com $${CHEF_ADMIN_PASSWORD} --filename /tmp/$${CHEF_ADMIN_PEM}
sudo chef-server-ctl org-create $${CHEF_DEMO_ORG} 'Demo Organization' --association_user $${CHEF_ADMIN} --filename /tmp/$${CHEF_DEMO_PEM}

# Install Chef Manage and reconfgigure/restart services
sudo chef-server-ctl install chef-manage
sudo chef-server-ctl reconfigure
sudo chef-manage-ctl reconfigure --accept-license

# Create our demo working directory, and setup for use with Chef/Knife
# TODO: refactor for RHEL/CentOS
cd /home/ubuntu
git clone https://github.com/tdsacilowski/vault-chef-approle-demo.git
cd /home/ubuntu/vault-chef-approle-demo/chef/
mkdir -p /home/ubuntu/vault-chef-approle-demo/chef/.chef
cp /tmp/*.pem /home/ubuntu/vault-chef-approle-demo/chef/.chef

tee /home/ubuntu/vault-chef-approle-demo/chef/.chef/knife.rb <<EOF
current_dir = File.dirname(__FILE__)
log_level                :info
log_location             STDOUT
node_name                '$${CHEF_ADMIN}'
client_key               "#{current_dir}/$${CHEF_ADMIN_PEM}"
validation_client_name   '$${CHEF_DEMO_ORG}-validator'
validation_key           "#{current_dir}/$${CHEF_DEMO_PEM}"
chef_server_url          '$${CHEF_SERVER_URL}/organizations/$${CHEF_DEMO_ORG}'
cache_type               'BasicFile'
cache_options( :path => "#{ENV['HOME']}/.chef/checksums" )
cookbook_path            ["#{current_dir}/../cookbooks"]
EOF

cd /home/ubuntu/vault-chef-approle-demo/chef/
knife ssl fetch
knife ssl check

cd /home/ubuntu/vault-chef-approle-demo/chef/cookbooks
knife cookbook upload vault_chef_approle_demo

chown -R ubuntu:ubuntu /home/ubuntu

logger "Complete"
