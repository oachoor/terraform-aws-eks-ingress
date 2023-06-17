# Terraform AWS EKS ALB Sandbox

## Requirements

- Terraform
- Kubectl
- Helm
- AWS CLI

## Deploy

```bash
terraform init
terraform apply
kubectl apply -f k8s/
```

## Auth

```bash
aws eks --region eu-central-1 update-kubeconfig --name ice-kube-cluster
```