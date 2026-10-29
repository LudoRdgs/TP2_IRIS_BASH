# TP2 IRIS : déploiement d'une VM Debian 13 en Bash

Script Bash qui déploie la VM `EISI-RODRIGUES-SRV01` sur le serveur iris.a3n.fr avec libvirt (`qemu:///system`).

TP réalisé dans le cadre du Mastère EISI à l'IRIS Nice (Linux avancé, jour 3).

## Ce que fait le script

1. Crée le réseau virtuel `RODRIGUES-SRV01-VNET` : `192.168.253.0/24` en NAT, avec la passerelle `192.168.253.1`. La VM obtient toujours l'adresse `192.168.253.10`, réservée par le DHCP grâce à son adresse MAC.
2. Crée le pool de stockage `RODRIGUES-SRV01` dans `~/libvirt/images/`.
3. Regarde si l'image Debian 13 est déjà sur le serveur. Sinon, il la télécharge, puis vérifie son empreinte SHA-512 auprès de Debian.
4. Copie l'image dans un disque autonome de 10 Go, fabrique l'ISO cloud-init (utilisateur `debian`, clé SSH dédiée) et crée la VM avec `virt-install` : 2 vCPU, 2 Go de RAM, disque et carte réseau virtio, démarrage UEFI.
5. Démarre la VM et affiche son adresse IP.

On peut relancer le script sans risque. Ce qui existe déjà (réseau, pool, VM) est réutilisé, rien n'est écrasé.

## Prérequis

- Un compte sur le serveur, membre du groupe `libvirt` (pas besoin de sudo).
- Les outils `virsh`, `virt-install`, `qemu-img`, `curl`, `xorriso` (ISO cloud-init) et `ssh-keygen` (le script crée lui-même la clé SSH de la VM).
- Le firmware UEFI OVMF (`/usr/share/OVMF/OVMF_CODE_4M.fd`).
- `setfacl` de préférence : le script donne au compte `libvirt-qemu`, qui exécute la VM, le droit de traverser le HOME pour atteindre le disque. Sans `setfacl`, il utilise `chmod o+x`.

## Utilisation

```bash
ssh iris
git clone https://github.com/LudoRdgs/TP2_IRIS_BASH.git
cd TP2_IRIS_BASH
bash deploy-vm.sh
```

Les paramètres (nom de la VM, IP, MAC, image, chemins) sont des variables au début de `deploy-vm.sh`.

## Connexion à la VM

La VM n'accepte qu'une seule clé : `~/.ssh/id_ed25519_eisi-rodrigues-srv01`, créée par le script dans le compte du serveur. La clé privée reste sur le serveur, donc seul ce compte peut se connecter à la VM.

```bash
ssh iris                                                              # depuis son poste
ssh -i ~/.ssh/id_ed25519_eisi-rodrigues-srv01 debian@192.168.253.10   # depuis iris
```

À la première connexion, SSH demande de confirmer l'empreinte de la VM. Avant de répondre `yes`, comparer avec l'empreinte relevée sur le réseau depuis iris :

```bash
ssh-keyscan -t ed25519 192.168.253.10 2>/dev/null | ssh-keygen -lf -
```

Une fois dans la VM, la commande `cloud-init status --wait` attend la fin de la configuration initiale.

## Vérifications

```bash
virsh -c qemu:///system dominfo EISI-RODRIGUES-SRV01
virsh -c qemu:///system domblklist EISI-RODRIGUES-SRV01 --details
virsh -c qemu:///system net-dhcp-leases RODRIGUES-SRV01-VNET
```

Dans la VM :

```bash
ip -br addr          # 192.168.253.10/24
ip route             # passerelle 192.168.253.1
lsblk                # disque vda de 10G
ping -c 1 deb.debian.org
```

## Supprimer et recréer la VM

Le script refuse d'écraser un disque existant. Pour repartir de zéro :

```bash
virsh -c qemu:///system destroy EISI-RODRIGUES-SRV01
virsh -c qemu:///system undefine EISI-RODRIGUES-SRV01 --nvram
rm ~/libvirt/images/RODRIGUES-SRV01/EISI-RODRIGUES-SRV01.qcow2 ~/libvirt/images/RODRIGUES-SRV01/EISI-RODRIGUES-SRV01-seed.iso
virsh -c qemu:///system pool-refresh RODRIGUES-SRV01
bash deploy-vm.sh
```

`--nvram` supprime aussi le fichier de variables UEFI de la VM. L'image Debian téléchargée et la clé SSH sont conservées et réutilisées.

## Remarque sur l'image

Le script utilise `debian-13-genericcloud-amd64-20261026-2643.qcow2`. La version `nocloud-riscv64` de la même date est prévue pour les processeurs RISC-V : elle ne démarre pas sur un serveur x86_64 et ne contient pas cloud-init.

La VM démarre en UEFI (firmware OVMF) : avec le QEMU 7.2 du serveur, les images Debian 13 restent bloquées après GRUB en mode BIOS.

## Problèmes rencontrés et corrections

| Symptôme | Cause | Correction |
|---|---|---|
| Le script s'arrête sans message pendant la recherche de l'image | `find` échoue sur des dossiers illisibles du HOME et `set -e` stoppe le script | `2>/dev/null \|\| true` sur `find` |
| `network is already active` | `virsh net-info` répond en français (`Actif : oui`) et le test `grep 'Active:.*yes'` ne trouve rien | tests avec `net-list`, `pool-list` et `list` sans `--all`, qui ne listent que les ressources actives |
| `pool ... already exists` | `pool-list --name` ajoute des espaces en fin de ligne, donc `grep -x` ne trouve pas le nom | fonction `in_list` qui retire les espaces avant la recherche |
| `Cannot access storage file ... Permission non accordée` | le compte `libvirt-qemu` ne peut pas traverser le HOME | ACL `u:libvirt-qemu:x` sur le HOME et les dossiers du pool |
| VM bloquée sur `Booting 'Debian GNU/Linux'`, pas d'IP | en mode BIOS, les images Debian 13 ne dépassent pas GRUB avec le QEMU 7.2 du serveur (testé avec QEMU directement : Debian 12 démarre en BIOS, Debian 13 seulement en UEFI) | démarrage UEFI (OVMF), disque autonome et ISO cloud-init créée par le script |
| `Permission denied (publickey)` | la clé proposée n'était pas installée dans la VM | clé dédiée créée sur le serveur et seule autorisée dans la VM |
