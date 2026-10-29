# TP2 IRIS : déploiement d'une VM Debian 13 en Bash

Script Bash qui déploie la VM `EISI-RODRIGUES-SRV01` sur le serveur iris.a3n.fr avec libvirt (`qemu:///system`).

TP réalisé dans le cadre du Mastère EISI à l'IRIS Nice (Linux avancé, jour 3).

## Ce que fait le script

1. Crée le réseau virtuel `RODRIGUES-SRV01-VNET` : `192.168.253.0/24` en NAT, avec la passerelle `192.168.253.1`. La VM obtient toujours l'adresse `192.168.253.10`, réservée par le DHCP grâce à son adresse MAC.
2. Crée le pool de stockage `RODRIGUES-SRV01` dans `~/libvirt/images/`.
3. Regarde si l'image Debian 13 est déjà sur le serveur. Sinon, il la télécharge, puis vérifie son empreinte SHA-512 auprès de Debian.
4. Copie l'image dans un disque autonome de 10 Go, fabrique l'ISO cloud-init (utilisateur `debian`, clés SSH) et crée la VM avec `virt-install` : 2 vCPU, 2 Go de RAM, disque et carte réseau virtio, démarrage UEFI.
5. Démarre la VM et affiche son adresse IP.

On peut relancer le script sans risque. Ce qui existe déjà (réseau, pool, VM) est réutilisé, rien n'est écrasé.

## Prérequis

- Un compte sur le serveur, membre du groupe `libvirt` (pas besoin de sudo).
- Les outils `virsh`, `virt-install`, `qemu-img` et `curl`.
- Une clé SSH publique dans `~/.ssh/authorized_keys`.

## Utilisation

```bash
ssh iris
git clone https://github.com/LudoRdgs/TP2_IRIS_BASH.git
cd TP2_IRIS_BASH
bash deploy-vm.sh
```

Les paramètres (nom de la VM, IP, MAC, image, chemins) sont des variables au début de `deploy-vm.sh`.

## Connexion à la VM

```bash
# depuis son poste, en passant par le serveur, avec la clé acceptée par iris
ssh -J iris -i ~/.ssh/iris_ed25519 debian@192.168.253.10
```

Une fois dans la VM, la commande `cloud-init status --wait` attend la fin de la configuration initiale.

## Vérifications

```bash
virsh -c qemu:///system dominfo EISI-RODRIGUES-SRV01
virsh -c qemu:///system domblklist EISI-RODRIGUES-SRV01 --details
virsh -c qemu:///system net-dhcp-leases RODRIGUES-SRV01-VNET
```

## Remarque sur l'image

Le script utilise `debian-13-genericcloud-amd64-20261026-2643.qcow2`. La version `nocloud-riscv64` de la même date est prévue pour les processeurs RISC-V : elle ne démarre pas sur un serveur x86_64 et ne contient pas cloud-init.

La VM démarre en UEFI (firmware OVMF) : avec le QEMU 7.2 du serveur, les images Debian 13 restent bloquées après GRUB en mode BIOS.
