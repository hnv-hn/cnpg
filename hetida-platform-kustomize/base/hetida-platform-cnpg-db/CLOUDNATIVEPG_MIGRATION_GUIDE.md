# CloudNativePG Migration Guide für TimescaleDB

## 📋 Inhaltsverzeichnis

1. [Voraussetzungen](#voraussetzungen)
2. [Installation](#installation)
3. [Cluster-Erstellung](#cluster-erstellung)
4. [Data Migration](#data-migration)
5. [Backup & Recovery](#backup--recovery)
6. [Monitoring](#monitoring)
7. [Troubleshooting](#troubleshooting)

## Voraussetzungen

### 1. CloudNativePG Operator Installation

```bash
# Add CloudNativePG Helm repository
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update

# Install CloudNativePG operator in kube-system namespace
helm install cnpg cnpg/cloudnative-pg \
  --namespace kube-system \
  --create-namespace \
  --set monitoring.enabled=true

# Verify installation
kubectl get deployment -n kube-system cnpg-cloudnative-pg
```

### 2. Longhorn Installation (falls nicht vorhanden)

```bash
# Add Longhorn Helm repository
helm repo add longhorn https://charts.longhorn.io
helm repo update

# Install Longhorn
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --set persistence.defaultClass=true \
  --set persistence.defaultClassReplicaCount=2

# Verify StorageClass
kubectl get storageclass
# Output sollte "longhorn" zeigen
```

### 3. Secrets vorbereiten

```bash
# Existing secret (sollte bereits existieren)
kubectl get secret hetida-platform-secrets -n hetida-platform-dev

# Falls nicht vorhanden, erstellen:
kubectl create secret generic hetida-platform-secrets \
  --from-literal=HETIDA-PLATFORM-TIMESCALE-DB-ADMIN-PASS='YourSecurePassword!' \
  -n hetida-platform-dev
```

## Installation

### 1. CloudNativePG Ressourcen applizieren

```bash
cd hetida-platform-kustomize/base/hetida-platform-cnpg-db

# Prüfen was deployed wird
kustomize build . | kubectl diff -f - -n hetida-platform-dev

# Deploy
kubectl apply -k . -n hetida-platform-dev

# Cluster-Status prüfen
kubectl get cluster timescale-db -n hetida-platform-dev -o wide
kubectl describe cluster timescale-db -n hetida-platform-dev
```

### 2. Cluster-Readiness checken

```bash
# Pods sollten running sein
kubectl get pods -n hetida-platform-dev -l postgresql.cnpg.io/cluster=timescale-db

# Leader Pod identifizieren
kubectl get pods -n hetida-platform-dev -L postgresql.cnpg.io/role

# Logs prüfen
kubectl logs timescale-db-1 -n hetida-platform-dev -f
```

## Cluster-Erstellung

### Cluster-Struktur

```
timescale-db-1 (Primary)   <- Read/Write
timescale-db-2 (Replica)   <- Read-Only, HA Failover
```

**Automatisch erstellte Ressourcen:**

- StatefulSet: `timescale-db`
- Service (Cluster-Internal): `timescale-db-rw` (Primary)
- Service (Read-Only): `timescale-db-r` (Replicas)
- PVCs: 2x `timescale-db-*` (je 100Gi mit Longhorn)
- PVCs: 2x `timescale-db-*-wal` (je 50Gi mit Longhorn)

### Zugriff auf die Datenbank

```bash
# Direkt auf Primary
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- psql -U tsadmin -d hetida_ts

# Über Service
psql -h timescale-db-rw.hetida-platform-dev.svc.cluster.local -U tsadmin -d hetida_ts
```

## Data Migration

### Szenario A: Migration vom alten StatefulSet

#### 1. Dump aus altem System erstellen

```bash
# Während altes System noch läuft
kubectl exec -it dev-timescale-db-0 -n hetida-platform-dev -- \
  pg_dump -U tsadmin -d hetida_ts -Fc > /tmp/hetida_ts.dump

# Größe überprüfen
ls -lh /tmp/hetida_ts.dump
```

#### 2. Dump in neues CloudNativePG Cluster importieren

```bash
# Copy dump in Pod
kubectl cp /tmp/hetida_ts.dump \
  timescale-db-1:/tmp/hetida_ts.dump \
  -n hetida-platform-dev

# Restore
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  pg_restore -U tsadmin -d hetida_ts -Fc /tmp/hetida_ts.dump --clean

# Cleanup
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  rm /tmp/hetida_ts.dump
```

#### 3. Validierung

```bash
# Zeilen im neuen Cluster zählen
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT COUNT(*) FROM timeseries;"

# Mit altem Cluster vergleichen
kubectl exec -it dev-timescale-db-0 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT COUNT(*) FROM timeseries;"

# TimescaleDB Extensions prüfen
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "\dx"
```

### Szenario B: Von Grund auf neuer Cluster

Cluster wird mit `bootstrap.initdb` Einstellungen erstellt - init-SQL wird automatisch ausgeführt.

```bash
# Verifizieren dass Extensions geladen sind
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT extname FROM pg_extension;"
```

## Backup & Recovery

### Automatische Backups

Tägliche Backups via CronJob um 2 AM:

```bash
# Backup-Status prüfen
kubectl get cronjob timescale-db-backup -n hetida-platform-dev

# Letzte Backup-Jobs prüfen
kubectl get jobs -n hetida-platform-dev -l app=timescale-db-backup --sort-by=.metadata.creationTimestamp

# Job-Logs prüfen
kubectl logs job/timescale-db-backup-xxx -n hetida-platform-dev
```

### Manuelle Backup erstellen

```bash
# Via kubectl patch
kubectl patch cluster timescale-db \
  --type merge \
  -p '{"metadata":{"annotations":{"cnpg.io/backup":"true"}}}' \
  -n hetida-platform-dev

# Backup-Status prüfen
kubectl get backups -n hetida-platform-dev
kubectl describe backup timescale-db-xxx -n hetida-platform-dev
```

### PITR - Point-in-Time Recovery

#### 1. Verfügbare Backups anzeigen

```bash
kubectl get backups -n hetida-platform-dev
kubectl get backups -n hetida-platform-dev -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.endWal}{"\n"}{end}'
```

#### 2. In neuen Cluster mit PITR restoren

```bash
# Cluster-Definition für Recovery
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: timescale-db-recovered
spec:
  bootstrap:
    recovery:
      backup:
        name: timescale-db-xxx  # Backup-Name
      recoveryTarget:
        timeline: latest
        targetTime: "2026-05-18 10:30:00"  # Optional: Spezifischer Zeitpunkt
  storage:
    size: 100Gi
    storageClass: longhorn
EOF
```

#### 3. PITR mit Longhorn Snapshots

```bash
# Verfügbare Snapshots anzeigen
kubectl get volumesnapshots -n hetida-platform-dev

# Snapshot erstellen
kubectl create -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: timescale-db-snapshot
spec:
  volumeSnapshotClassName: longhorn
  source:
    persistentVolumeClaimName: timescale-db-1
EOF

# Snapshot als neue PVC restoren
kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: timescale-db-restored
spec:
  storageClassName: longhorn
  dataSource:
    name: timescale-db-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
EOF
```

## Monitoring

### Prometheus Integration

CloudNativePG exportiert automatisch Metriken auf Port 9187:

```bash
# Metriken abrufen
kubectl port-forward svc/timescale-db-monitoring 9187:9187 -n hetida-platform-dev

# Curl test
curl http://localhost:9187/metrics | grep cnpg

# Wichtige Metriken:
# - cnpg_pg_stat_replication_*
# - cnpg_pg_postmaster_start_time_seconds
# - cnpg_pg_database_*
```

### PrometheusRule (automatisch erstellt)

```bash
kubectl get prometheusrule -n hetida-platform-dev
kubectl describe prometheusrule timescale-db -n hetida-platform-dev
```

### Grafana Dashboard

Fertige Dashboards für CloudNativePG:

- https://grafana.com/grafana/dashboards/20857

```bash
# Import in bestehende Grafana Instanz
# oder als ConfigMap:
kubectl create configmap grafana-cnpg-dashboard \
  --from-file=dashboard.json \
  -n monitoring
```

## Troubleshooting

### 1. Cluster wird nicht gestartet

```bash
# Events prüfen
kubectl describe cluster timescale-db -n hetida-platform-dev

# Logs der Operator prüfen
kubectl logs -n kube-system -l app.kubernetes.io/name=cloudnative-pg -f

# PVCs prüfen
kubectl get pvc -n hetida-platform-dev
kubectl describe pvc timescale-db-1 -n hetida-platform-dev
```

### 2. Replica ist nicht in Sync

```bash
# Replication Status
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT * FROM pg_stat_replication;"

# WAL-Sender Status
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT pid, usename, application_name, state, write_lsn FROM pg_stat_replication;"
```

### 3. Backup fehlgeschlagen

```bash
# Backup-Status detailliert
kubectl describe backup timescale-db-xxx -n hetida-platform-dev

# barman Logs prüfen (wenn vorhanden)
kubectl logs timescale-db-1 -n hetida-platform-dev | grep barman

# Disk-Space überprüfen
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  df -h /var/lib/postgresql/data
```

### 4. Performance Probleme

```bash
# Top Queries
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT query, calls, total_time, mean_time FROM pg_stat_statements ORDER BY total_time DESC LIMIT 10;"

# Cache Hit Ratio
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT sum(blks_hit) / (sum(blks_hit) + sum(blks_read)) as cache_hit_ratio FROM pg_statio_user_tables;"

# Connection Count
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
  psql -U tsadmin -d hetida_ts -c "SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;"
```

## Wichtige Links

- [CloudNativePG Dokumentation](https://cloudnative-pg.io/)
- [CloudNativePG API Reference](https://cloudnative-pg.io/documentation/current/api_reference/)
- [TimescaleDB Dokumentation](https://docs.timescale.com/)
- [Longhorn Dokumentation](https://longhorn.io/)
- [PostgreSQL Point-in-Time Recovery](https://www.postgresql.org/docs/current/continuous-archiving.html)
