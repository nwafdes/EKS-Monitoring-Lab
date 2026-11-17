# vm-monitoring-lab

A disposable AWS lab that mirrors a central-monitoring setup: a **central** EKS cluster (VictoriaMetrics cluster version + Grafana) and an optional **worker** EKS cluster (vmagent + apps) that pushes metrics to it. It's built to be cheap and to be destroyed after every session.

## What gets created

| Layer | Resources |
|---|---|
| Network | VPC `10.50.0.0/16`, 2 public `/24` + 2 private `/19` subnets in 2 AZs, internet gateway, **1 zonal NAT gateway** (public subnet, AZ 1), public + private route tables |
| Central cluster | EKS control plane, 1× `t4g.large` node (arm64, private subnet), add-ons: vpc-cni, kube-proxy, coredns, eks-pod-identity-agent, aws-ebs-csi-driver |
| Worker cluster (optional) | Same, with 1× `t4g.medium` node |

Design choices:

- **Pods stay private.** Nodes run only in private subnets; outbound internet goes through the NAT gateway.
- **All nodes sit in AZ 1**, the same AZ as the NAT gateway. That avoids cross-AZ data charges, and an EBS volume (vmstorage, Grafana) can always re-attach after a node is replaced.
- **Both clusters accept TCP from the whole VPC**, so the worker's vmagent can reach central's vminsert.
- **Subnet tags** (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`) are in place, so you can add internal or public load balancers later.

## Cost (us-east-1, on-demand, while running)

| Item | $/hr |
|---|---|
| EKS control plane (each) | 0.10 |
| t4g.large (central node) | 0.0672 |
| t4g.medium (worker node) | 0.0336 |
| NAT gateway (+ $0.045/GB processed) | 0.045 |
| NAT Elastic IP (public IPv4) | 0.005 |
| **Central only** | **≈ 0.22** |
| **Central + worker** | **≈ 0.35** |

EBS (20 GB root disk per node, plus small PVCs) adds a few cents per day. **Destroy everything when you finish a session.**

## Prerequisites

- An IAM user or role (not root) with admin rights; it becomes cluster admin automatically.
- Terraform >= 1.6, AWS CLI v2, kubectl, helm.

## Usage

```bash
git clone <this-repo> && cd vm-monitoring-lab
terraform init
terraform plan      # read it before you apply
terraform apply     # asks: "Create the WORKER cluster too? Type yes or no"
```

Creation takes about 15–20 minutes. When both clusters are requested, Terraform builds them in parallel.

Then connect kubectl (Terraform prints these commands as outputs):

```bash
$(terraform output -raw central_kubeconfig_command)
$(terraform output -raw worker_kubeconfig_command)   # only if you created the worker

kubectl --context central get nodes
kubectl --context central apply -f k8s/storageclass-gp3.yaml   # default StorageClass for PVCs
```

To skip the prompt: `terraform apply -var create_worker=no`.

## Teardown (do this in order)

`terraform destroy` only removes what Terraform created. Anything Kubernetes created in AWS must go first, or the destroy gets stuck or leaves costs behind:

```bash
# 1. Remove LoadBalancer Services: their load balancers block subnet/VPC deletion
kubectl --context central get svc -A | grep LoadBalancer
# 2. Uninstall Helm releases and delete PVCs: their EBS volumes are otherwise orphaned and still billed
helm --kube-context central list -A
kubectl --context central get pvc -A
# 3. Then destroy (it asks the worker question again; either answer destroys everything in state)
terraform destroy
```

Check afterwards: EC2 → Volumes and EC2 → Load Balancers should show nothing tagged for this lab.

## Notes

- Running `apply` again and answering **no** removes an existing worker cluster.
- `kubernetes_version` must stay in EKS **standard** support. A version in extended support bills the control plane at $0.60/hr instead of $0.10.
- To lock the EKS API to your IP, set `-var 'public_access_cidrs=["<your-ip>/32"]'`.
- `capacity_type=SPOT` lowers node cost, but a single Spot node can be reclaimed in the middle of a session.
