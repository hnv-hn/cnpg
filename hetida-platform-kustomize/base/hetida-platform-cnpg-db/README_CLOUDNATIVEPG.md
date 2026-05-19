# CloudNativePG TimescaleDB Setup mit Longhorn

Diese Verzeichnis enthält die Kubernetes-Ressourcen für das neue CloudNativePG-basierte TimescaleDB-Setup mit Longhorn Storage und automatisierten Backups.

## 📁 Dateistruktur

### Core CloudNativePG Ressourcen

- **`cloudnativepg-cluster.yaml`** - CloudNativePG Cluster CRD mit allen Konfigurationen
  - 2 Replicas (Primary + Standby)
  - Longhorn Storage (100Gi + 50Gi WAL)
  - TimescaleDB Extensions + Init-SQL
  - WAL-Archivierung und Backup-Konfiguration

- **`longhorn-storageclass.yaml`** - Longhorn StorageClass für CloudNativePG
  - 2-fache Replikation
  - Snapshot-fähig
  - Wait-for-first-consumer binding

### Datenbank-Konfiguration

- **`timescale-init-sql.yaml`** - Init-Script für Datenbank
  - TimescaleDB Extension
  - Hypertable für Zeitserien-Daten
  - Indizes und Kompression-Policies

- **`pgbackrest-config.yaml`** - pgBackRest Konfiguration
  - Backup-Retention (30 Tage)
  - Compression-Settings
  - Lokale Backups über Longhorn

### Backup & Recovery

- **`backup-cronjob.yaml`** - Automatische tägliche Backups
  - Läuft täglich um 2:00 Uhr
  - Trigger via CloudNativePG API
  - RBAC-Konfiguration für Service Account

### Alte Ressourcen (deprecated)

Folgende Dateien sind aus dem alten StatefulSet-Setup. Können nach erfolgreicher Migration gelöscht werden:

- `timescale-db-pvc.yaml` - Alte PVCs
- `timescale-db-wal-pvc.yaml` - Alte WAL-PVCs
- `timescale-db-stateful-set.yaml` - Altes StatefulSet
- `timescale-db-svc.yaml` - Alter Service
- `timescale-db-init-script.yaml` - Altes Init-Script
- `postgres-config.yaml` - Alte Postgres-Config
- `timescale-db-basebackup-cronjob.yaml` - Altes Backup-Script

### Tools & Dokumentation

- **`migrate.sh`** - Automatisiertes Migrations-Script
  - Dump vom alten System
  - Import in neues System
  - Validierung der Daten
- **`CLOUDNATIVEPG_MIGRATION_GUIDE.md`** - Umfassender Installations- und Migrations-Guide
  - Installation Voraussetzungen
  - Schritt-für-Schritt Anleitung
  - Data Migration
  - Backup & Recovery Verfahren
  - Troubleshooting

## 🚀 Quick Start

### 1. Voraussetzungen überprüfen

```bash
# CloudNativePG Operator
helm list -A | grep cloudnative-pg

# Longhorn
kubectl get storageclass | grep longhorn
```

### 2. Cluster deployen

```bash
cd hetida-platform-kustomize/base/hetida-platform-cnpg-db

# Trockentest
kustomize build . | kubectl diff -f - -n hetida-platform-dev

# Deploy
kubectl apply -k . -n hetida-platform-dev

# Status prüfen
kubectl get cluster timescale-db -n hetida-platform-dev -o wide
```

### 3. Daten migrieren

```bash
# Automatisiertes Migrations-Script nutzen
./migrate.sh

# Oder manuell (siehe CLOUDNATIVEPG_MIGRATION_GUIDE.md)
```

## 📊 Cluster-Struktur

```
TimescaleDB Cluster (2 Replicas)
├── timescale-db-1 (Primary)
│   ├── 100Gi Data (Longhorn PVC) [2x replicated]
│   └── 50Gi WAL Archive (Longhorn PVC) [2x replicated]
│
├── timescale-db-2 (Standby Replica)
│   ├── 100Gi Data (Longhorn PVC) [2x replicated]
│   └── 50Gi WAL Archive (Longhorn PVC) [2x replicated]
│
├── Services
│   ├── timescale-db-rw (Primary) - Read/Write
│   ├── timescale-db-r (Replicas) - Read-Only
│   └── timescale-db-ro (Read-Only, can use Primary)
│
└── Automated Backups
    ├── Daily CronJob (02:00 Uhr)
    ├── 30 Tage Retention
    └── PITR via Longhorn Snapshots
```

## 🔑 Wichtige Befehle

### Cluster Management

```bash
# Cluster Status
kubectl get cluster timescale-db -n hetida-platform-dev -o wide

# Pods anzeigen
kubectl get pods -n hetida-platform-dev -l postgresql.cnpg.io/cluster=timescale-db

# Leader identifizieren
kubectl get pods -n hetida-platform-dev -L postgresql.cnpg.io/role

# Logs
kubectl logs timescale-db-1 -n hetida-platform-dev -f

# In Cluster einsteigen
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- psql -U tsadmin -d hetida_ts
```

### Backup & Recovery

```bash
# Manuelle Backup triggern
kubectl patch cluster timescale-db --type merge \
  -p '{"metadata":{"annotations":{"cnpg.io/backup":"true"}}}' \
  -n hetida-platform-dev

# Backups anzeigen
kubectl get backups -n hetida-platform-dev

# Backup Details
kubectl describe backup timescale-db-xxx -n hetida-platform-dev

# PITR Restore (siehe Guide)
```

### Monitoring

```bash
# Metriken abrufen
kubectl port-forward svc/timescale-db-monitoring 9187:9187 -n hetida-platform-dev
curl http://localhost:9187/metrics | grep cnpg

# Replication Status
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT * FROM pg_stat_replication;"
```

## 🔧 Konfigurationstipps

### StorageClass Anpassen

Für höhere Performance, Replikationszahl oder andere Longhorn-Features in `longhorn-storageclass.yaml`:

```yaml
parameters:
  numberOfReplicas: '3' # Mehr Replikation = höhere Verfügbarkeit
  staleReplicaTimeout: '2880' # Zeit bis Replica als "stale" gilt
```

### Backup Destination konfigurieren

Dieses Setup verwendet ausschließlich Longhorn und lokale Backups. Für Remote-Backups zu S3/Minio ist keine Konfiguration in dieser Umgebung erforderlich.

### Resource-Limits anpassen

In `cloudnativepg-cluster.yaml`:

```yaml
resources:
  requests:
    memory: 2Gi
    cpu: 1000m
  limits:
    memory: 4Gi
    cpu: 2000m
```

## 🐛 Troubleshooting

Siehe **`CLOUDNATIVEPG_MIGRATION_GUIDE.md`** Abschnitt "Troubleshooting" für häufige Probleme und Lösungen.

## 📚 Weitere Ressourcen

- [CloudNativePG Dokumentation](https://cloudnative-pg.io/)
- [TimescaleDB Dokumentation](https://docs.timescale.com/)
- [Longhorn Dokumentation](https://longhorn.io/)
- [PostgreSQL PITR](https://www.postgresql.org/docs/current/continuous-archiving.html)

## 🔄 Migration von altem Setup

Das `migrate.sh` Script automatisiert die gesamte Migration:

```bash
./migrate.sh
```

Das Script:

1. ✅ Prüft Voraussetzungen
2. ✅ Erstellt Dump aus altem System
3. ✅ Kopiert Dump in neuen Cluster
4. ✅ Führt Restore durch
5. ✅ Validiert Datenmigration
6. ✅ Räumt auf

Detaillierte manuelle Schritte siehe `CLOUDNATIVEPG_MIGRATION_GUIDE.md`.

## ⚠️ Wichtige Hinweise

- **Replicas**: 2 Replicas als Standard, können auf 3+ erhöht werden
- **Storage**: Longhorn mit 2x Replikation ist mit 3+ Nodes sicherer
- **Backup**: Tägliche Backups um 02:00 UTC - ggf. anpassen
- **WAL Archivierung**: Lokal in Longhorn
- **PITR**: Möglich bis zu konfigurierten Retention (default: 30 Tage)

---

**Status**: ✅ Produktionsreif nach Migrations-Validierung
**Kontakt**: DevOps Team
