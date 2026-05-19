#!/bin/bash
#SBATCH --job-name=nccl-allreduce-1node
#SBATCH --partition=slinky
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=8
#SBATCH --gres=gpu:8
#SBATCH --output=/shared/output/nccl-allreduce-1node-%j.out
#SBATCH --error=/shared/output/nccl-allreduce-1node-%j.err
#SBATCH --time=00:30:00

mkdir -p /shared/output

export NCCL_DEBUG=INFO
export NCCL_DEBUG_SUBSYS=INIT,ENV

# MPI control traffic over pod network
export OMPI_MCA_btl=self,tcp
export OMPI_MCA_btl_tcp_if_include=eth0
export NCCL_SOCKET_IFNAME=eth0

# RDMA fabric — B300 exposes 16 RoCE NICs (mlx5_0..mlx5_15, 2 per GPU)
export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9,mlx5_10,mlx5_11,mlx5_12,mlx5_13,mlx5_14,mlx5_15
export NCCL_NET_GDR_LEVEL=5
export NCCL_IB_GID_INDEX=3

srun --mpi=pmix \
  all_reduce_perf \
  -b 1 -e 16G -f 2 -g 1 -c 1 -n 100
