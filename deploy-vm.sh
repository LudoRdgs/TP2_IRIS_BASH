#!/bin/bash
# Arrête le script sur une erreur (-e), une variable non définie (-u)
# ou une erreur dans n'importe quelle commande d'un pipeline (pipefail).
set -euo pipefail

# Connexion au libvirt système du serveur, imposée par le sujet.
# Le compte est membre du groupe libvirt : pas besoin de sudo.
# Le mode qemu:///session ne permet pas de créer un réseau NAT.
LIBVIRT_URI="qemu:///system"
# Nom de la machine virtuelle demandé par la consigne.
VM_NAME="EISI-RODRIGUES-SRV01"
# Nom du fichier image Debian 13 Trixie (x86_64, avec cloud-init).
# L'image nocloud-riscv64 de la consigne est prévue pour un processeur RISC-V :
# elle ne démarre pas sur ce serveur x86_64 et ne contient pas cloud-init.
OS_IMAGE_NAME="debian-13-genericcloud-amd64-20261026-2643.qcow2"
# URL de téléchargement de l'image, construite à partir de son nom.
OS_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/20261026-2643/${OS_IMAGE_NAME}"
# Nom du pool de stockage, défini avant POOL_DIR qui l'utilise (sinon set -u arrête le script).
POOL_NAME="RODRIGUES-SRV01"
# Dossier du pool, placé dans le répertoire personnel du compte.
POOL_DIR="${HOME}/libvirt/images/${POOL_NAME}"
# Chemin du disque de la VM, rangé dans le pool.
VM_DISK="${POOL_DIR}/${VM_NAME}.qcow2"
# Support cloud-init NoCloud (ISO nommée « cidata ») lu par la VM au premier démarrage.
SEED_ISO="${POOL_DIR}/${VM_NAME}-seed.iso"
# Nom du réseau virtuel libvirt de la VM.
VNET_NAME="RODRIGUES-SRV01-VNET"
# Nom du pont créé par libvirt sur le serveur (15 caractères au maximum).
VNET_BRIDGE="br-rod01"
# Adresse MAC fixe de la carte réseau (52:54:00 est le préfixe réservé à QEMU/KVM).
# Elle permet au DHCP de toujours attribuer la même adresse IP à la VM.
VM_MAC="52:54:00:25:30:10"
# Adresse IP demandée pour la VM, réservée dans le DHCP du réseau virtuel.
VM_IP="192.168.253.10"
# Fichier contenant la clé SSH publique du poste, déjà utilisée pour se connecter au serveur.
# Elle sera copiée dans la VM (cloud-init) pour l'utilisateur debian.
SSH_KEY_FILE="${HOME}/.ssh/authorized_keys"

# Vérifie si NOM apparaît dans la liste renvoyée par une commande virsh (ex. : in_list "$VM_NAME" list --name).
# La liste est d'abord récupérée en entier, puis les espaces de début et de fin de ligne sont retirés :
# grep ne coupe plus la sortie de virsh en cours d'écriture et le nom est comparé exactement.
in_list() {
    local name=$1
    local list
    shift
    list=$(virsh -c "$LIBVIRT_URI" "$@" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    grep -Fxq -- "$name" <<< "$list"
}

# Crée, démarre et rend automatique le réseau virtuel 192.168.253.0/24 en NAT.
setup_vnet() {
    # Chemin du fichier XML temporaire qui décrit le réseau.
    local xml_file
    # Liste tous les réseaux, même arrêtés, et cherche le nom exact du nôtre.
    # Le réseau n'est défini que s'il n'existe pas encore : le script peut être relancé.
    if ! in_list "$VNET_NAME" net-list --all --name; then
        # Crée un fichier temporaire vide pour y écrire la définition XML.
        xml_file=$(mktemp)
        # Écrit tout le texte jusqu'à EOF dans le fichier, en remplaçant les variables.
        cat > "$xml_file" <<EOF
<network>
  <name>${VNET_NAME}</name>
  <!-- NAT : la VM accède à Internet par le serveur, sans être joignable de l'extérieur. -->
  <forward mode='nat'/>
  <bridge name='${VNET_BRIDGE}' stp='on' delay='0'/>
  <!-- Passerelle de la VM et réseau /24 (254 adresses utilisables). -->
  <ip address='192.168.253.1' netmask='255.255.255.0'>
    <dhcp>
      <!-- Plage d'adresses distribuées automatiquement. -->
      <range start='192.168.253.100' end='192.168.253.200'/>
      <!-- Réservation : la carte VM_MAC reçoit toujours VM_IP, hors de la plage ci-dessus. -->
      <host mac='${VM_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>
    </dhcp>
  </ip>
</network>
EOF
        # Enregistre le réseau dans libvirt, sans le démarrer.
        virsh -c "$LIBVIRT_URI" net-define "$xml_file"
        # Supprime le fichier temporaire devenu inutile.
        rm -f "$xml_file"
    fi

    # Démarre le réseau (pont et DHCP) seulement s'il n'est pas déjà actif.
    # Sans --all, net-list ne liste que les réseaux actifs : ce test ne dépend pas
    # de la langue de virsh (net-info affiche « Actif : oui » sur un serveur en français).
    if ! in_list "$VNET_NAME" net-list --name; then
        virsh -c "$LIBVIRT_URI" net-start "$VNET_NAME"
    fi
    # Redémarre le réseau automatiquement avec le serveur ; la commande peut être relancée.
    virsh -c "$LIBVIRT_URI" net-autostart "$VNET_NAME"
    # Confirme que le réseau est prêt.
    echo "Réseau prêt : $VNET_NAME (192.168.253.0/24, IP de la VM : $VM_IP)"
}

# Crée et démarre le pool de stockage libvirt, puis active son démarrage automatique.
setup_pool() {
    # Crée le dossier et ses parents sans erreur s'il existe déjà (-p).
    # 0711 : seul le propriétaire lit et écrit ; QEMU peut traverser le dossier
    # pour ouvrir le disque, sans pouvoir lister son contenu.
    mkdir -p "$POOL_DIR" && chmod 0711 "$POOL_DIR"
    # QEMU tourne sous le compte libvirt-qemu : il doit pouvoir traverser (droit x) le HOME
    # et les dossiers parents du pool pour atteindre le disque.
    # L'ACL donne ce droit au seul compte libvirt-qemu, sans ouvrir le HOME aux autres étudiants.
    # Sans la commande setfacl, on se rabat sur o+x (traversée sans lecture du contenu).
    if command -v setfacl >/dev/null 2>&1; then
        setfacl -m u:libvirt-qemu:x "$HOME" "$HOME/libvirt" "$HOME/libvirt/images"
    else
        chmod o+x "$HOME" "$HOME/libvirt" "$HOME/libvirt/images"
    fi
    # Ne définit le pool que s'il n'existe pas déjà dans libvirt.
    if ! in_list "$POOL_NAME" pool-list --all --name; then
        # Déclare un pool de type répertoire pointant vers POOL_DIR.
        virsh -c "$LIBVIRT_URI" pool-define-as "$POOL_NAME" dir --target "$POOL_DIR"
    fi

    # Démarre le pool uniquement s'il n'est pas déjà actif.
    # Sans --all, pool-list ne liste que les pools actifs (indépendant de la langue).
    if ! in_list "$POOL_NAME" pool-list --name; then
        virsh -c "$LIBVIRT_URI" pool-start "$POOL_NAME"
    fi
    # Configure libvirt pour démarrer ce pool à chaque démarrage du serveur.
    virsh -c "$LIBVIRT_URI" pool-autostart "$POOL_NAME"
    # Confirme que le pool est prêt.
    echo "Pool de stockage prêt : $POOL_NAME ($POOL_DIR)"
}

# Vérifie si l'image Debian 13 est déjà sur le serveur, la télécharge sinon,
# puis contrôle son intégrité avec les empreintes publiées par Debian.
setup_os() {
    # Chemin de l'image trouvée dans le répertoire personnel, s'il y en a une.
    local existing_image
    # Cherche dans tout le HOME un fichier portant le nom de l'image et s'arrête au premier trouvé.
    # Les dossiers illisibles (ex. données Docker) font échouer find : on masque ces messages
    # et "|| true" empêche set -e d'arrêter le script.
    existing_image=$(find "$HOME" -type f -name "$OS_IMAGE_NAME" -print -quit 2>/dev/null || true)
    # Si la recherche a renvoyé un chemin, l'image est déjà sur le serveur : on la réutilise.
    if [[ -n "$existing_image" ]]; then
        OS_IMAGE="$existing_image"
        echo "Image Debian 13 déjà présente : $OS_IMAGE"
    else
        # Sinon, l'image sera stockée dans le pool.
        OS_IMAGE="$POOL_DIR/$OS_IMAGE_NAME"
        echo "Téléchargement de l'image Debian 13 depuis $OS_IMAGE_URL..."
        # -f : échoue sur une erreur HTTP au lieu d'enregistrer la page d'erreur ; -L : suit les redirections.
        # Le fichier .part évite de confondre un téléchargement interrompu avec une image complète.
        curl -fL -o "$OS_IMAGE.part" "$OS_IMAGE_URL"
        # Donne son nom définitif à l'image une fois le téléchargement terminé.
        mv "$OS_IMAGE.part" "$OS_IMAGE"
        echo "Image téléchargée et stockée dans : $OS_IMAGE"
    fi

    # Se place dans le dossier de l'image, car sha512sum -c cherche le fichier dans le dossier courant.
    cd "$(dirname "$OS_IMAGE")"
    # Récupère SHA512SUMS dans le même dossier que l'image (${OS_IMAGE_URL%/*} retire le nom du fichier),
    # garde la ligne de notre image et compare l'empreinte ; le script s'arrête si elle diffère.
    curl -fsSL "${OS_IMAGE_URL%/*}/SHA512SUMS" | grep " ${OS_IMAGE_NAME}$" | sha512sum -c -
    # Revient au dossier de départ sans afficher son chemin.
    cd - >/dev/null
}

# Crée le disque virtuel et définit la machine virtuelle dans libvirt.
create_vm() {
    # Si la VM existe déjà, ne modifie rien et passe à la suite sans erreur.
    if virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
        echo "La VM $VM_NAME existe déjà ; aucune modification effectuée."
        return 0
    fi

    # Un disque sans VM indique une tentative précédente interrompue :
    # le script s'arrête pour ne pas écraser de données.
    if [[ -e "$VM_DISK" ]]; then
        echo "Le disque de la VM existe déjà : $VM_DISK" >&2
        echo "Vérifiez la VM avant de relancer le script" >&2
        exit 1
    fi
    # Copie complète de l'image Debian dans un disque autonome (sans fichier de base),
    # puis agrandissement à 10 Go. L'image d'origine reste intacte pour une prochaine VM.
    qemu-img convert -O qcow2 "$OS_IMAGE" "$VM_DISK"
    qemu-img resize "$VM_DISK" 10G

    # Prépare les fichiers cloud-init dans un dossier temporaire.
    local seed_dir
    seed_dir=$(mktemp -d)
    # user-data : compte debian sans mot de passe, connexion uniquement par les clés SSH
    # du fichier SSH_KEY_FILE, sudo dans la VM. Les lignes vides et les commentaires sont ignorés.
    {
        echo "#cloud-config"
        echo "hostname: eisi-rodrigues-srv01"
        echo "users:"
        echo "  - name: debian"
        echo "    shell: /bin/bash"
        echo "    lock_passwd: true"
        echo "    sudo: ALL=(ALL) NOPASSWD:ALL"
        echo "    ssh_authorized_keys:"
        grep -E '^(ssh-|ecdsa-)' "$SSH_KEY_FILE" | sed 's/^/      - /'
        echo "ssh_pwauth: false"
    } > "$seed_dir/user-data"
    # meta-data : identifiant d'instance fixe (cloud-init ne rejoue pas la première configuration)
    # et nom d'hôte de la VM.
    printf 'instance-id: %s\nlocal-hostname: %s\n' "iid-eisi-rodrigues-srv01" "eisi-rodrigues-srv01" > "$seed_dir/meta-data"
    # Fabrique l'ISO NoCloud : le nom de volume doit être « cidata » pour que cloud-init la trouve.
    xorriso -as mkisofs -quiet -o "$SEED_ISO" -V cidata -J -r "$seed_dir/user-data" "$seed_dir/meta-data"
    rm -rf "$seed_dir"
    # Demande à libvirt de relire le dossier du pool pour y voir le disque et l'ISO.
    virsh -c "$LIBVIRT_URI" pool-refresh "$POOL_NAME"

    # Crée et démarre la VM : 2 Go de RAM, 2 vCPU, disque et carte réseau virtio.
    # La carte est branchée sur notre réseau avec la MAC réservée, ce qui lui donne 192.168.253.10.
    # L'ISO cloud-init est branchée en lecteur CD-ROM et reste attachée.
    # Démarrage UEFI (firmware OVMF, sans Secure Boot) : sur ce serveur (QEMU 7.2), les images
    # Debian 13 restent bloquées après GRUB en mode BIOS, alors qu'elles démarrent en UEFI.
    # Pas d'écran graphique : seulement une console série, accessible avec virsh console.
    # --import démarre sur le disque existant, sans installation depuis un ISO.
    # --autostart relance la VM avec le serveur ; --noautoconsole rend la main tout de suite.
    virt-install --connect "$LIBVIRT_URI" \
        --name "$VM_NAME" \
        --memory 2048 \
        --vcpus 2 \
        --disk "path=$VM_DISK,format=qcow2,bus=virtio" \
        --disk "path=$SEED_ISO,device=cdrom" \
        --os-variant debian13 \
        --network "network=$VNET_NAME,mac=$VM_MAC,model=virtio" \
        --boot "loader=/usr/share/OVMF/OVMF_CODE_4M.fd,loader.readonly=yes,loader.type=pflash,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.fd" \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --autostart \
        --noautoconsole
    # Confirme les principales ressources attribuées à la VM.
    echo "VM créée avec succès : $VM_NAME (2 vCPUs, 2 Go RAM, disque de 10 Go)"
}

# Démarre la VM si elle ne tourne pas déjà, puis affiche l'adresse IP attribuée.
start_vm() {
    # La VM doit exister à cette étape, sinon le script s'arrête en erreur.
    if ! virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
        echo "La VM $VM_NAME n'existe pas ; impossible de la démarrer." >&2
        exit 1
    fi

    # virt-install démarre déjà la VM : dans ce cas, simple message sans erreur.
    # Sans --all, list ne liste que les VM en cours d'exécution (indépendant de la langue).
    if in_list "$VM_NAME" list --name; then
        echo "La VM $VM_NAME est déjà en cours d'exécution."
    else
        # Démarre la VM définie dans libvirt.
        virsh -c "$LIBVIRT_URI" start "$VM_NAME"
        echo "VM démarrée avec succès : $VM_NAME"
    fi
    # Affiche les baux DHCP pour vérifier que la VM a bien reçu 192.168.253.10.
    virsh -c "$LIBVIRT_URI" net-dhcp-leases "$VNET_NAME"
}

# Exécute les étapes dans l'ordre : réseau, stockage, image, création puis démarrage de la VM.
setup_vnet
setup_pool
setup_os
create_vm
start_vm
