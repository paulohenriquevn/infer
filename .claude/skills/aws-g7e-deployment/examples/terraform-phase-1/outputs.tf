# Illustrative, not applied, not tested.

output "instance_id" {
  value = aws_instance.replica.id
}

output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.replica.id} --region ${var.region}"
}

output "kernel_cache_volume_id" {
  value = aws_ebs_volume.kernel_cache.id
}
