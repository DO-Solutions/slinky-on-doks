# Placeholders __NFS_HOST__ and __NFS_PATH__ are replaced by `make nfs/configure`
apiVersion: v1
kind: PersistentVolume
metadata:
  name: slurm-nfs-pv
  labels:
    type: nfs-slurm-storage
spec:
  capacity:
    storage: 1000Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: __NFS_HOST__
    path: __NFS_PATH__
  mountOptions:
    - vers=4.1
    - nconnect=16
    - rsize=1048576
    - wsize=1048576
