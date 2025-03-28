resource "null_resource" "update_control_plane_script" {
  depends_on = [aws_lb.k8s_api_lb]

  provisioner "local-exec" {
    command = <<-EOT
      sed -i 's/LOAD_BALANCER_DNS/${aws_lb.k8s_api_lb.dns_name}/g' ${path.module}/scripts/control_plane_init.sh.tpl
    EOT
  }
}