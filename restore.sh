#!/bin/bash
# ============================================================
#  restore_www.sh - Déchiffrement + restauration de /var/www/html
# ============================================================

set -euo pipefail

# ---------- Configuration ----------
BACKUP_ROOT="/backup"
ARCHIVE_DIR="${BACKUP_ROOT}/archives"
KEY_DIR="${BACKUP_ROOT}/keys"
RESTORE_DIR="/var/www"

CLEANUP_KEY=0
ARCHIVE_PLAIN=""

cleanup() {
    [[ -n "$ARCHIVE_PLAIN" && -f "$ARCHIVE_PLAIN" ]] && rm -f "$ARCHIVE_PLAIN"
    [[ "$CLEANUP_KEY" -eq 1 && -n "${KEY_FILE:-}" && -f "$KEY_FILE" ]] && rm -f "$KEY_FILE"
}
trap cleanup EXIT

# ---------- Vérifications ----------
[[ $EUID -eq 0 ]] || { echo "[ERREUR] Exécuter en root (sudo)." >&2; exit 1; }
command -v openssl >/dev/null || { echo "[ERREUR] openssl manquant." >&2; exit 1; }

# ---------- Menu : choix de l'archive ----------
clear
echo "============================================================"
echo "   Restauration de sauvegardes chiffrées"
echo "============================================================"
echo "Archives disponibles dans $ARCHIVE_DIR :"
echo

mapfile -t ARCHIVES < <(ls -1t "${ARCHIVE_DIR}"/*.tar.gz.enc 2>/dev/null || true)

if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
    echo "Aucune archive trouvée."
    exit 1
fi

for i in "${!ARCHIVES[@]}"; do
    SIZE=$(du -h "${ARCHIVES[$i]}" | cut -f1)
    DATE=$(date -r "${ARCHIVES[$i]}" '+%Y-%m-%d %H:%M:%S')
    printf "  %2d) %-45s (%s, %s)\n" "$((i+1))" "$(basename "${ARCHIVES[$i]}")" "$SIZE" "$DATE"
done

echo
read -rp "Numéro de l'archive à restaurer (ou 'q' pour quitter) : " SEL
[[ "$SEL" == "q" ]] && exit 0
[[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#ARCHIVES[@]} )) || {
    echo "Choix invalide."; exit 1;
}

ARCHIVE_ENC="${ARCHIVES[$((SEL-1))]}"
BASENAME=$(basename "$ARCHIVE_ENC" .tar.gz.enc)
KEY_FILE="${KEY_DIR}/${BASENAME}.key"
ARCHIVE_PLAIN="/tmp/${BASENAME}.tar.gz"

# ---------- Vérification de la clé ----------
if [[ -f "$KEY_FILE" ]]; then
    echo
    echo "Clé trouvée automatiquement : $KEY_FILE"
    read -rp "Utiliser cette clé ? [O/n] : " USE_KEY
    if [[ "${USE_KEY,,}" == "n" ]]; then
        KEY_FILE=""
    fi
fi

if [[ -z "${KEY_FILE:-}" || ! -f "$KEY_FILE" ]]; then
    echo
    echo "Entrez la clé de déchiffrement (collez la valeur base64) :"
    read -r MANUAL_KEY
    [[ -n "$MANUAL_KEY" ]] || { echo "Clé vide, abandon."; exit 1; }
    TMP_KEY=$(mktemp)
    chmod 600 "$TMP_KEY"
    printf '%s' "$MANUAL_KEY" > "$TMP_KEY"
    KEY_FILE="$TMP_KEY"
    CLEANUP_KEY=1
fi

# ---------- Déchiffrement ----------
echo
echo "Déchiffrement de l'archive..."
if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$ARCHIVE_ENC" -out "$ARCHIVE_PLAIN" -pass file:"$KEY_FILE"; then
    echo "[ERREUR] Échec du déchiffrement (mauvaise clé ?)." >&2
    exit 1
fi
echo "Déchiffrement OK -> $ARCHIVE_PLAIN"

# ---------- Choix de la destination ----------
echo
read -rp "Restaurer dans [$RESTORE_DIR] ? (Entrée = oui, sinon indiquez un chemin) : " DEST
DEST="${DEST:-$RESTORE_DIR}"

read -rp "ATTENTION : le dossier 'html' existant dans $DEST sera écrasé. Continuer ? [o/N] : " CONF
[[ "${CONF,,}" == "o" ]] || { echo "Annulé."; exit 0; }

# ---------- Sauvegarde de l'existant ----------
if [[ -d "${DEST}/html" ]]; then
    SAFE="${DEST}/html.bak.$(date +%Y%m%d_%H%M%S)"
    echo "Sauvegarde de l'existant -> $SAFE"
    mv "${DEST}/html" "$SAFE"
fi

# ---------- Extraction ----------
mkdir -p "$DEST"
echo "Extraction dans $DEST ..."
tar -xzf "$ARCHIVE_PLAIN" -C "$DEST"

# ---------- Permissions correctes pour Apache ----------
if id www-data >/dev/null 2>&1; then
    chown -R www-data:www-data "${DEST}/html"
    find "${DEST}/html" -type d -exec chmod 755 {} \;
    find "${DEST}/html" -type f -exec chmod 644 {} \;
    echo "Permissions appliquées (www-data:www-data)."
fi

echo
echo "=== Restauration terminée avec succès ==="
echo "Contenu restauré : ${DEST}/html"s