# Mise en place du cronjob de sauvegarde automatique

## 1. Installer le script

```bash
sudo cp backup.sh /usr/local/sbin/backup.sh
sudo chmod 700 /usr/local/sbin/backup.sh
```

Le script accepte un argument `--auto` : dans ce mode, aucune question n'est posée
(sauvegarde complète, clé conservée), ce qui le rend compatible avec une exécution
non interactive via cron. Sans cet argument, le menu interactif habituel s'affiche.

## 2. Éditer le crontab de root

```bash
sudo crontab -e
```

Au premier lancement, le système demande de choisir un éditeur (nano ou vim selon
ce qui est installé). Ajouter **une seule ligne**, tout en bas du fichier :

```
*/5 * * * * /usr/local/sbin/backup.sh --auto >> /var/log/backup_cron.log 2>&1
```

### Lecture de la ligne
| Champ | Valeur | Signification |
|---|---|---|
| minute | `*/5` | toutes les 5 minutes (0, 5, 10, 15...) |
| heure | `*` | toutes les heures |
| jour du mois | `*` | tous les jours |
| mois | `*` | tous les mois |
| jour de la semaine | `*` | tous les jours de la semaine |
| commande | `/usr/local/sbin/backup.sh --auto` | exécution du script en mode automatique |
| redirection | `>> /var/log/backup_cron.log 2>&1` | sortie standard **et** erreurs redirigées vers le fichier log |

### Sauvegarder et quitter
- **Avec nano** : `Ctrl+O` puis `Entrée` (sauvegarder), puis `Ctrl+X` (quitter)
- **Avec vim** : `Échap` puis taper `:wq` puis `Entrée`

## 3. Vérifications post-installation

```bash
# La ligne est-elle bien enregistrée, sans caractère parasite ?
sudo crontab -l | cat -A
# la ligne doit se terminer exactement par 2>&1$ (le $ = fin de ligne affichée par cat -A)

# Le service cron tourne-t-il ?
sudo systemctl status cron

# Le script est-il bien présent et exécutable ?
ls -l /usr/local/sbin/backup.sh
```

## 4. Tester le script comme le ferait cron

Un `sudo commande >> fichier` en ligne de commande **ne reproduit pas** les
conditions du cron : la redirection `>>` est interprétée par le shell de
l'utilisateur courant (pas root), ce qui peut donner une erreur "Permission
denied" alors que le cron, lui, fonctionnera normalement (toute la ligne
tourne en root dans le crontab). Pour tester à l'identique :

```bash
sudo bash -c '/usr/local/sbin/backup.sh --auto >> /var/log/backup_cron.log 2>&1'
cat /var/log/backup_cron.log
```

## 5. Suivre l'exécution automatique

```bash
# Voir si cron a bien déclenché le script
sudo journalctl -u cron | tail -20

# Voir le log de sortie du script
cat /var/log/backup_cron.log

# Voir les archives produites
ls -lt /backup/archives/ | head
```

Après 10-15 minutes, plusieurs archives horodatées (`backup_www_html_YYYYMMDD_HHMMSS.tar.gz.enc`)
doivent apparaître dans `/backup/archives/`.

## Points d'attention

- **Rétention** : à raison d'une sauvegarde toutes les 5 minutes, ça fait ~288
  archives par jour. Le script purge automatiquement (en mode `--auto`) les
  archives, clés et logs de plus de 7 jours (`RETENTION_DAYS` dans le script,
  ajustable).
- **Durée d'exécution** : si `/var/www/html` est volumineux, s'assurer que
  `tar` + `openssl enc` se termine bien en moins de 5 minutes, sinon les
  exécutions se chevauchent (cron ne vérifie pas si l'instance précédente
  tourne encore).
- **Caractères parasites** : en cas de blocage inexpliqué (rien dans le log,
  cron déclenché mais aucune archive produite), vérifier avec
  `sudo crontab -l | cat -A` qu'aucun caractère invisible ne s'est glissé
  dans la ligne (arrive facilement en tapant par erreur en mode insertion
  de vim avant `:wq`).