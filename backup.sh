#!/bin/bash
# ============================================================
#  backup_www.sh - Sauvegarde chiffrée de /var/www/html
# ============================================================

set -euo pipefail

# ---------- Configuration ----------
SOURCE_DIR="/var/www/html"
BACKUP_ROOT="/backup"
ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"
LOG_DIR="${BACKUP_ROOT}/logs"

# ---------- Fonctions utilitaires ----------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

die() {
    echo "[ERREUR] $*" >&2
    exit 1
}

# Nettoyage automatique en cas d'échec en cours de route
cleanup_on_error() {
    local ec=$?
    if [[ $ec -ne 0 ]]; then
        echo "[ERREUR] Échec (code $ec), nettoyage des fichiers partiels..." >&2
        [[ -n "${ARCHIVE_PLAIN:-}" && -f "${ARCHIVE_PLAIN:-}" ]] && rm -f "$ARCHIVE_PLAIN"
        [[ -n "${ARCHIVE_ENC:-}" && -f "${ARCHIVE_ENC:-}" ]] && rm -f "$ARCHIVE_ENC"
    fi
}
trap cleanup_on_error EXIT

# ---------- Vérifications ----------
[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root (sudo)."
[[ -d "$SOURCE_DIR" ]] || die "Le dossier source $SOURCE_DIR n'existe pas."
command -v openssl >/dev/null || die "openssl n'est pas installé."
command -v tar >/dev/null || die "tar n'est pas installé."

umask 077
mkdir -p "$ARCHIVE_DIR" "$KEY_DIR" "$LOG_DIR"

# ---------- Menu interactif ----------
clear
echo "============================================================"
echo "   Sauvegarde chiffrée de : $SOURCE_DIR"
echo "============================================================"
echo "1) Sauvegarde complète (archive + chiffrement symétrique AES-256)"
echo "2) Sauvegarde chiffrée + suppression de la clé après usage"
echo "3) Quitter"
echo "============================================================"
read -rp "Votre choix [1-3] : " CHOICE

case "$CHOICE" in
    1) DELETE_KEY_AFTER=0 ;;
    2) DELETE_KEY_AFTER=1 ;;
    3) trap - EXIT; echo "Annulé."; exit 0 ;;
    *) die "Choix invalide." ;;
esac

# ---------- Horodatage commun (clé + archive) ----------
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BASENAME="backup_www_html_${TIMESTAMP}"
ARCHIVE_PLAIN="${ARCHIVE_DIR}/${BASENAME}.tar.gz"
ARCHIVE_ENC="${ARCHIVE_DIR}/${BASENAME}.tar.gz.enc"
KEY_FILE="${KEY_DIR}/${BASENAME}.key"
LOG_FILE="${LOG_DIR}/${BASENAME}.log"

log "=== Début de la sauvegarde : $BASENAME ==="

# ---------- Génération de la clé symétrique (256 bits) ----------
log "Génération de la clé AES-256..."
# tr supprime le retour à la ligne pour éviter toute ambiguïté
# entre openssl enc et openssl dec sur le contenu exact du fichier clé.
openssl rand -base64 32 | tr -d '\n' > "$KEY_FILE"
chmod 600 "$KEY_FILE"
log "Clé générée : $KEY_FILE"

# ---------- Création de l'archive tar.gz ----------
log "Création de l'archive : $ARCHIVE_PLAIN"
tar -czf "$ARCHIVE_PLAIN" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"
log "Archive créée : $(du -h "$ARCHIVE_PLAIN" | cut -f1)"

# ---------- Chiffrement symétrique AES-256-CBC ----------
log "Chiffrement AES-256-CBC de l'archive..."
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in  "$ARCHIVE_PLAIN" \
    -out "$ARCHIVE_ENC" \
    -pass file:"$KEY_FILE"

log "Archive chiffrée : $ARCHIVE_ENC ($(du -h "$ARCHIVE_ENC" | cut -f1))"

# ---------- Suppression de l'archive en clair ----------
rm -f "$ARCHIVE_PLAIN"
log "Archive non chiffrée supprimée."

# ---------- Option : suppression de la clé ----------
if [[ "$DELETE_KEY_AFTER" -eq 1 ]]; then
    log "ATTENTION : la clé va être supprimée. Notez-la avant de continuer !"
    echo
    echo "===== CLÉ DE DÉCHIFFREMENT ====="
    cat "$KEY_FILE"
    echo
    echo "================================"
    echo
    read -rp "Avez-vous bien noté la clé ? [o/N] : " CONFIRM
    if [[ "${CONFIRM,,}" == "o" ]]; then
        shred -u "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
        log "Clé supprimée : $KEY_FILE"
    else
        log "Conservation de la clé : $KEY_FILE"
    fi
fi

log "=== Sauvegarde terminée avec succès ==="
echo
echo "Archive : $ARCHIVE_ENC"
echo "Clé     : $KEY_FILE"
echo "Log     : $LOG_FILE"

trap - EXIT