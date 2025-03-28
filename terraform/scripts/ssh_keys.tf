resource "null_resource" "generate_ssh_key" {
  count = fileexists(pathexpand(var.public_key_path)) ? 0 : 1

  provisioner "local-exec" {
    command = <<-EOT
      ssh-keygen -t rsa -b 2048 -f ${pathexpand("~/.ssh/id_rsa_aws")} -N ""
    EOT
  }
}
