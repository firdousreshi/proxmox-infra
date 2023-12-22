# Generate a random cluster token for k3s
resource "random_id" "k3s_token" {
  byte_length = 35
}
resource "random_password" "db_password" {
  length  = 16
  special = false
}


locals {
  kubeconfig_path = "${path.module}/kubeconfig"
  db_user         = "k3s"
  db              = "kubernetes"
  db_port         = 3306
  db_password     = random_password.db_password.result
}

# Create the VM that will contain the database
resource "proxmox_vm_qemu" "k3s-db" {
  name        = "k3s-db"
  desc        = "Kubernetes MariaDB database. User: ${local.db_user} | Password: ${local.db_password} | DB: ${local.db}"
  target_node = "proxmox"

  # Hardware configuration
  agent   = 1
  clone   = "ubuntu-server-jammy"
  cores   = 1
  memory  = 1024
  balloon = 512
  sockets = 1
  cpu     = "host"
  disk {
    storage = "local"
    type    = "virtio"
    size    = "20G"
  }

  os_type         = "cloud-init"
  ipconfig0       = "ip=dhcp" # auto-assign a IP address for the machine
  nameserver      = "1.1.1.1"
  ciuser          = var.ciuser
  sshkeys         = file("~/.ssh/id_rsa.pub")
  ssh_user        = var.ciuser
  ssh_private_key = file("~/.ssh/id_rsa")

  # Specify connection variables for remote execution
  connection {
    type        = "ssh"
    host        = self.ssh_host # Auto-assigned ip address
    user        = self.ssh_user
    private_key = self.ssh_private_key
    port        = self.ssh_port
    timeout     = "10m"

  }

   provisioner "remote-exec" {
    inline = [<<EOF
      sudo apt-get update
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server

      # Start and enable MariaDB service
      sudo systemctl start mariadb
      sudo systemctl enable mariadb

      # Set MariaDB root password
      sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${local.db_password}'"

      # Create a user and database
      sudo mysql -e "CREATE DATABASE IF NOT EXISTS ${local.db}"
      sudo mysql -e "CREATE USER IF NOT EXISTS '${local.db_user}'@'localhost' IDENTIFIED BY '${local.db_password}'"
      sudo mysql -e "GRANT ALL PRIVILEGES ON ${local.db}.* TO '${local.db_user}'@'localhost'"
      sudo mysql -e "FLUSH PRIVILEGES"
    EOF
    ]
  }

locals {
  # Create the datastore endpoint for the cluster
  datastore_endpoint = "mysql://${local.db_user}:${random_password.db_password.result}@tcp(${proxmox_vm_qemu.k3s-db.ssh_host}:${local.db_port})/${local.db}"
}



resource "proxmox_vm_qemu" "k3s-nodes" {
  depends_on  = [proxmox_vm_qemu.k3s-db]
  count       = var.node_count
  name        = "k3s-${count.index}"
  desc        = "Kubernetes node ${count.index}"
  target_node = "proxmox"

  # Hardware configuration
  agent   = 1
  clone   = "ubuntu-server-jammy"
  cores   = var.cores
  memory  = var.memory
  balloon = 512
  sockets = 1
  cpu     = "host"
  disk {
    storage = "local"
    type    = "virtio"
    size    = var.disk_size
  }

  os_type         = "cloud-init"
  ipconfig0       = "ip=dhcp" # auto-assign a IP address for the machine
  nameserver      = "1.1.1.1"
  ciuser          = var.ciuser
  sshkeys         = file("~/.ssh/id_rsa.pub")
  ssh_user        = var.ciuser
  ssh_private_key = file("~/.ssh/id_rsa")

  # Specify connection variables for remote execution
  connection {
    type        = "ssh"
    host        = self.ssh_host # Auto-assigned ip address
    user        = self.ssh_user
    private_key = self.ssh_private_key
    port        = self.ssh_port
    timeout     = "10m"

  }


  # Provision the kubernetes cluster with k3sup
  provisioner "local-exec" {
    command = <<-EOT
      # Generate SSH private key file
      echo "${self.ssh_private_key}" > privkey
      chmod 600 privkey

      # First two nodes are server nodes for High Availability setup.
      # The next nodes are just agent nodes for deploying workloads
      if [ "${count.index}" -lt 2 ]; then
        echo "Installing server node"
        k3sup install --ip ${self.ssh_host} \
          --k3s-extra-args "--disable local-storage" \
          --user ${self.ssh_user} \
          --ssh-key privkey \
          --k3s-version ${var.k3s_version} \
          --datastore="${local.datastore_endpoint}" \
          --token=${random_id.k3s_token.b64_std} \ 
          --local-path="${local.kubeconfig_path}"
      else
        echo "Installing agent node"
        k3sup join --ip ${self.ssh_host} \
          --user ${self.ssh_user} \
          --server-user ${self.ssh_user} \
          --ssh-key privkey \
          --k3s-version ${var.k3s_version} \
          --server-ip ${proxmox_vm_qemu.k3s-nodes[0].ssh_host}
      fi

      # Cleanup private key
      rm privkey
    EOT
  }

  # For some reason terraform has changes on reapply
  # https://github.com/Telmate/terraform-provider-proxmox/issues/112
  lifecycle {
    ignore_changes = [
      network,
    ]
  }

}

resource "null_resource" "configure_dns_servers" {
  # This configuration is needed because we will deploy Pihole as DNS on port 53
  # and the VM will be unable to perform DNS lookups because the default nameserver
  # is "127.0.0.53". We need to set it to an upstream server such as Google, Cloudflare
  count = var.node_count
  # Trigger to always run this resource
  triggers = {
    always_run = timestamp()
  }
  # And run only after nodes have been provisioned
  depends_on = [proxmox_vm_qemu.k3s-nodes]

  # Specify connection variables for remote execution
  connection {
    type        = "ssh"
    host        = proxmox_vm_qemu.k3s-nodes[count.index].ssh_host
    user        = proxmox_vm_qemu.k3s-nodes[count.index].ssh_user
    private_key = proxmox_vm_qemu.k3s-nodes[count.index].ssh_private_key
    port        = proxmox_vm_qemu.k3s-nodes[count.index].ssh_port
    timeout     = "10m"
  }
  provisioner "remote-exec" {
    inline = [
      # Based on https://askubuntu.com/a/1346001
      # Make sure cloudflare is setup as nameserver, otherwise apt update and install commands wont work
      "if ! grep -q 'nameserver 1.1.1.1' /etc/resolv.conf; then echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf; fi",
      "sudo apt update -y -qq 2>/dev/null >/dev/null;",
      "sudo apt install resolvconf -y -qq 2>/dev/null >/dev/null;",
      # Only add nameservers to file if they don't exist already
      "grep -qxF 'nameserver 1.1.1.1' /etc/resolvconf/resolv.conf.d/head || echo 'nameserver 1.1.1.1' | sudo tee -a /etc/resolvconf/resolv.conf.d/head",
      "grep -qxF 'nameserver 8.8.8.8' /etc/resolvconf/resolv.conf.d/head || echo 'nameserver 8.8.8.8' | sudo tee -a /etc/resolvconf/resolv.conf.d/head",
      "sudo systemctl restart resolvconf.service",
      "sudo systemctl restart systemd-resolved",
      # Enable qemu guest agent
      "sudo systemctl enable --now qemu-guest-agent"
    ]
  }
}

# Create a bucket
#resource "aws_s3_bucket" "k3s" {
  #bucket = "k3s"
  #acl    = "private" # or can be "public-read"
  #tags = {
    #Name = "Kubernetes cluster"
  #}
  #depends_on = [proxmox_vm_qemu.k3s-nodes]
#}
# Upload the KUBECONFIG to s3
#resource "aws_s3_object" "kubeconfig" {
  #bucket = aws_s3_bucket.k3s.id
  #key    = "kubeconfig"
  #source = "./kubeconfig"
#}