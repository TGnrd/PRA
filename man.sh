#!/bin/bash
# ============================================================
#  backup_restore_www.sh - Sauvegarde et restauration chiffrées
#                           de /var/www/html
# ============================================================

set -euo pipefail

# ---------- Configuration ----------
SOURCE_DIR="/var/www/html"
BACKUP_ROOT="/backup"
ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"
LOG_DIR="${BACKUP_ROOT}/logs"
RESTORE_DIR="/var/www"

# ---------- Fonctions utilitaires ----------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

die() {
    echo "[ERREUR] $*" >&2
    exit 1
}

require_root_and_tools() {
    [[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root (sudo)."
    command -v openssl >/dev/null || die "openssl n'est pas installé."
    command -v tar >/dev/null || die "tar n'est pas installé."
}

# ============================================================
#  SAUVEGARDE
# ============================================================
do_backup() {
    [[ -d "$SOURCE_DIR" ]] || die "Le dossier source $SOURCE_DIR n'existe pas."

    umask 077
    mkdir -p "$ARCHIVE_DIR" "$KEY_DIR" "$LOG_DIR"

    echo "1) Sauvegarde complète (archive + chiffrement AES-256)"
    echo "2) Sauvegarde chiffrée + suppression de la clé après usage"
    echo "3) Retour au menu principal"
    read -rp "Votre choix [1-3] : " CHOICE

    case "$CHOICE" in
        1) DELETE_KEY_AFTER=0 ;;
        2) DELETE_KEY_AFTER=1 ;;
        3) return 0 ;;
        *) die "Choix invalide." ;;
    esac

    local timestamp basename archive_plain archive_enc key_file
    timestamp=$(date '+%Y%m%d_%H%M%S')
    basename="backup_www_html_${timestamp}"
    archive_plain="${ARCHIVE_DIR}/${basename}.tar.gz"
    archive_enc="${ARCHIVE_DIR}/${basename}.tar.gz.enc"
    key_file="${KEY_DIR}/${basename}.key"
    LOG_FILE="${LOG_DIR}/${basename}.log"

    # Nettoyage automatique si une étape échoue
    trap 'rm -f "$archive_plain" "$archive_enc" 2>/dev/null' ERR

    log "=== Début de la sauvegarde : $basename ==="

    log "Génération de la clé AES-256..."
    openssl rand -base64 32 | tr -d '\n' > "$key_file"
    chmod 600 "$key_file"
    log "Clé générée : $key_file"

    log "Création de l'archive : $archive_plain"
    tar -czf "$archive_plain" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"
    log "Archive créée : $(du -h "$archive_plain" | cut -f1)"

    log "Chiffrement AES-256-CBC de l'archive..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in  "$archive_plain" \
        -out "$archive_enc" \
        -pass file:"$key_file"
    log "Archive chiffrée : $archive_enc ($(du -h "$archive_enc" | cut -f1))"

    rm -f "$archive_plain"
    log "Archive non chiffrée supprimée."

    if [[ "$DELETE_KEY_AFTER" -eq 1 ]]; then
        log "ATTENTION : la clé va être supprimée. Notez-la avant de continuer !"
        echo
        echo "===== CLÉ DE DÉCHIFFREMENT ====="
        cat "$key_file"
        echo
        echo "================================"
        echo
        read -rp "Avez-vous bien noté la clé ? [o/N] : " CONFIRM
        if [[ "${CONFIRM,,}" == "o" ]]; then
            shred -u "$key_file" 2>/dev/null || rm -f "$key_file"
            log "Clé supprimée : $key_file"
        else
            log "Conservation de la clé : $key_file"
        fi
    fi

    trap - ERR
    log "=== Sauvegarde terminée avec succès ==="
    echo
    echo "Archive : $archive_enc"
    echo "Clé     : $key_file"
    echo "Log     : $LOG_FILE"
}

# ============================================================
#  RESTAURATION
# ============================================================
do_restore() {
    local archives=() archive_enc basename key_file archive_plain
    local cleanup_key=0

    mapfile -t archives < <(ls -1t "${ARCHIVE_DIR}"/*.tar.gz.enc 2>/dev/null || true)
    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "Aucune archive trouvée dans $ARCHIVE_DIR."
        return 1
    fi

    echo "Archives disponibles :"
    echo
    for i in "${!archives[@]}"; do
        local size date
        size=$(du -h "${archives[$i]}" | cut -f1)
        date=$(date -r "${archives[$i]}" '+%Y-%m-%d %H:%M:%S')
        printf "  %2d) %-45s (%s, %s)\n" "$((i+1))" "$(basename "${archives[$i]}")" "$size" "$date"
    done

    echo
    read -rp "Numéro de l'archive à restaurer (ou 'q' pour annuler) : " SEL
    [[ "$SEL" == "q" ]] && return 0
    [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#archives[@]} )) || {
        echo "Choix invalide."; return 1;
    }

    archive_enc="${archives[$((SEL-1))]}"
    basename=$(basename "$archive_enc" .tar.gz.enc)
    key_file="${KEY_DIR}/${basename}.key"
    archive_plain="/tmp/${basename}.tar.gz"

    # Nettoyage automatique de l'archive déchiffrée / clé temporaire
    trap 'rm -f "$archive_plain"; [[ "$cleanup_key" -eq 1 ]] && rm -f "$key_file" 2>/dev/null' RETURN

    if [[ -f "$key_file" ]]; then
        echo
        echo "Clé trouvée automatiquement : $key_file"
        read -rp "Utiliser cette clé ? [O/n] : " USE_KEY
        [[ "${USE_KEY,,}" == "n" ]] && key_file=""
    fi

    if [[ -z "${key_file:-}" || ! -f "$key_file" ]]; then
        echo
        echo "Entrez la clé de déchiffrement (collez la valeur base64) :"
        read -r manual_key
        [[ -n "$manual_key" ]] || { echo "Clé vide, abandon."; return 1; }
        local tmp_key
        tmp_key=$(mktemp)
        chmod 600 "$tmp_key"
        printf '%s' "$manual_key" > "$tmp_key"
        key_file="$tmp_key"
        cleanup_key=1
    fi

    echo
    echo "Déchiffrement de l'archive..."
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
            -in "$archive_enc" -out "$archive_plain" -pass file:"$key_file"; then
        echo "[ERREUR] Échec du déchiffrement (mauvaise clé ?)." >&2
        return 1
    fi
    echo "Déchiffrement OK -> $archive_plain"

    echo
    read -rp "Restaurer dans [$RESTORE_DIR] ? (Entrée = oui, sinon indiquez un chemin) : " DEST
    DEST="${DEST:-$RESTORE_DIR}"

    read -rp "ATTENTION : le dossier 'html' existant dans $DEST sera écrasé. Continuer ? [o/N] : " CONF
    [[ "${CONF,,}" == "o" ]] || { echo "Annulé."; return 0; }

    if [[ -d "${DEST}/html" ]]; then
        local safe
        safe="${DEST}/html.bak.$(date +%Y%m%d_%H%M%S)"
        echo "Sauvegarde de l'existant -> $safe"
        mv "${DEST}/html" "$safe"
    fi

    mkdir -p "$DEST"
    echo "Extraction dans $DEST ..."
    tar -xzf "$archive_plain" -C "$DEST"

    if id www-data >/dev/null 2>&1; then
        chown -R www-data:www-data "${DEST}/html"
        find "${DEST}/html" -type d -exec chmod 755 {} \;
        find "${DEST}/html" -type f -exec chmod 644 {} \;
        echo "Permissions appliquées (www-data:www-data)."
    fi

    echo
    echo "=== Restauration terminée avec succès ==="
    echo "Contenu restauré : ${DEST}/html"
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================
require_root_and_tools

clear
echo "============================================================"
echo "   Sauvegarde / Restauration chiffrée de : $SOURCE_DIR"
echo "============================================================"
echo "1) Sauvegarder"
echo "2) Restaurer"
echo "3) Quitter"
echo "============================================================"
read -rp "Votre choix [1-3] : " MAIN_CHOICE

case "$MAIN_CHOICE" in
    1) do_backup ;;
    2) do_restore ;;
    3) echo "Annulé."; exit 0 ;;
    *) die "Choix invalide." ;;
esac