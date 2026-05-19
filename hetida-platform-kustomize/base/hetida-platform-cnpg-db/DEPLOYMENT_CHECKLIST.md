# CloudNativePG Deployment Checklist

## Phase 1: Vorbereitung (vor dem Deployment)

### Cluster-Umgebung

- [ ] Kubernetes Cluster verfügbar (1.23+)
- [ ] 3+ Worker Nodes für Longhorn Replikation
- [ ] Genug Disk-Space: Min. 300Gi verfügbar
- [ ] Genug Memory: Min. 4Gi pro Node
- [ ] kubectl CLI konfiguriert

### Namespace

- [ ] Namespace existiert: `hetida-platform-dev`
  ```bash
  kubectl create namespace hetida-platform-dev
  ```

### Secrets

- [ ] `hetida-platform-secrets` existiert mit DB-Passwort
  ```bash
  kubectl get secret hetida-platform-secrets -n hetida-platform-dev
  ```

## Phase 2: Operator Installation

### CloudNativePG Operator

- [ ] Helm Repository hinzufügen

  ```bash
  helm repo add cnpg https://cloudnative-pg.github.io/charts
  helm repo update
  ```

- [ ] Operator installieren

  ```bash
  helm install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system \
    --create-namespace \
    --version 0.23.2 \
    --set monitoring.enabled=true
  ```

- [ ] Operator läuft
  ```bash
  kubectl get deployment -n kube-system -l app.kubernetes.io/name=cloudnative-pg
  ```

### Longhorn (falls nicht vorhanden)

- [ ] Longhorn installieren (oder Alternative)

  ```bash
  helm repo add longhorn https://charts.longhorn.io
  helm install longhorn longhorn/longhorn -n longhorn-system --create-namespace
  ```

- [ ] StorageClass "longhorn" verfügbar
  ```bash
  kubectl get storageclass longhorn
  ```

### Prometheus Operator CRDs installieren (falls nicht vorhanden)

Prüfen:

```bash
kubectl get crd | grep monitoring.coreos.com
```

Erwarten:

```Code
prometheusrules.monitoring.coreos.com
servicemonitors.monitoring.coreos.com
podmonitors.monitoring.coreos.com
alertmanagers.monitoring.coreos.com
```

Wenn nichts kommt, installieren:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 60.0.0
```

### CNPG CRDs

## Phase 3: Deployment

### CloudNativePG Ressourcen

- [ ] In korrektes Verzeichnis wechseln

  ```bash
  cd hetida-platform-kustomize/base/hetida-platform-cnpg-db
  ```

- [ ] Dry-Run durchführen

  ```bash
  kubectl kustomize . | kubectl diff -f - -n hetida-platform-dev
  ```

- [ ] Ressourcen deployen

  ```bash
  kubectl apply -k . -n hetida-platform-dev
  ```

- [ ] Cluster wird erstellt
  ```bash
  kubectl get cluster timescale-db -n hetida-platform-dev
  ```

### Cluster-Readiness

- [ ] Alle Pods starten

  ```bash
  kubectl get pods -n hetida-platform-dev -l postgresql.cnpg.io/cluster=timescale-db
  ```

  Erwartet: 2 Pods im Status `Running`

- [ ] PVCs werden erstellt

  ```bash
  kubectl get pvc -n hetida-platform-dev | grep timescale-db
  ```

  Erwartet: 4 PVCs (2x Data, 2x WAL)

- [ ] Cluster ist in Status "Ready"

  ```bash
  kubectl get cluster timescale-db -n hetida-platform-dev -o wide
  kubectl describe cluster timescale-db -n hetida-platform-dev
  ```

  Erwartet: Status=Ready, Current Primary exists

- [ ] Primary Pod identifizieren

  ```bash
  kubectl get pods -n hetida-platform-dev -L postgresql.cnpg.io/role
  ```

  Erwartet: Einer mit Role=primary, einer mit Role=replica

## Phase 4: Datenbank-Validierung

### Datenbank erreichbar

- [ ] Primary Pod betreten

  ```bash
  kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
    psql -U tsadmin -d hetida_ts
  ```

  Erwartet: `hetida_ts=#` prompt

- [ ] Datenbank-Info prüfen

  ```bash
  psql> \l
  ```

  Erwartet: DB `hetida_ts` existiert

- [ ] TimescaleDB Extension prüfen

  ```bash
  psql> \dx
  ```

  Erwartet: `timescaledb` Extension vorhanden

- [ ] Hypertable prüfen

  ```bash
  psql> SELECT tablename FROM pg_tables WHERE schemaname='public';
  psql> \d timeseries
  ```

  Erwartet: `timeseries` Hypertable existiert

## Phase 5: Replication & HA

### Replication Status

- [ ] Replikation läuft

  ```bash
  kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
    psql -U tsadmin -d hetida_ts -c \
    "SELECT * FROM pg_stat_replication;"
  ```

  Erwartet: 1 Replica-Eintrag mit state="streaming"

- [ ] WAL Level ist replica

  ```bash
  psql> SHOW wal_level;
  ```

  Erwartet: `replica`

- [ ] Max WAL Senders

  ```bash
  psql> SHOW max_wal_senders;
  ```

  Erwartet: > 1

## Phase 6: Data Migration (falls von altem System)

### Migration Script

- [ ] Migration Script ist vorhanden

  ```bash
  ls -l migrate.sh
  chmod +x migrate.sh
  ```

- [ ] Altes System läuft noch

  ```bash
  kubectl get pod dev-timescale-db-0 -n hetida-platform-dev
  ```

- [ ] Migration durchführen

  ```bash
  ./migrate.sh
  ```

  Script sollte:
  - ✓ Dump aus altem System erstellen
  - ✓ Dump validieren
  - ✓ In neues System kopieren
  - ✓ Restore durchführen
  - ✓ Datenmigration validieren
  - ✓ Cleanup durchführen

- [ ] Row Count überprüfen

  ```bash
  # Beide sollten gleich sein
  kubectl exec -it dev-timescale-db-0 -n hetida-platform-dev -- \
    psql -U tsadmin -d hetida_ts -c "SELECT COUNT(*) FROM timeseries;"

  kubectl exec -it timescale-db-1 -n hetida-platform-dev -- \
    psql -U tsadmin -d hetida_ts -c "SELECT COUNT(*) FROM timeseries;"
  ```

## Phase 7: Backup & Recovery

### Backup-Konfiguration

- [ ] CronJob für Backups existiert

  ```bash
  kubectl get cronjob -n hetida-platform-dev | grep timescale-db-backup
  ```

- [ ] Backup Schedule prüfen

  ```bash
  kubectl get cronjob timescale-db-backup -n hetida-platform-dev -o yaml | grep schedule
  ```

  Erwartet: `"0 2 * * *"` (02:00 Uhr täglich)

### Manuelles Backup testen

- [ ] Backup triggern

  ```bash
  kubectl patch cluster timescale-db --type merge \
    -p '{"metadata":{"annotations":{"cnpg.io/backup":"true"}}}' \
    -n hetida-platform-dev
  ```

- [ ] Backup-Status prüfen

  ```bash
  kubectl get backups -n hetida-platform-dev
  kubectl describe backup timescale-db-xxx -n hetida-platform-dev
  ```

  Erwartet: Backup completed erfolgreich

## Phase 8: Monitoring

### Prometheus Metriken

- [ ] Metriken verfügbar

  ```bash
  kubectl port-forward svc/timescale-db-monitoring 9187:9187 \
    -n hetida-platform-dev
  # In anderer Shell:
  curl http://localhost:9187/metrics | head -20
  ```

- [ ] CloudNativePG Metriken
  ```bash
  curl http://localhost:9187/metrics | grep cnpg | head -5
  ```

### Logging

- [ ] Cluster Logs prüfen

  ```bash
  kubectl logs timescale-db-1 -n hetida-platform-dev -f --tail=20
  ```

  Erwartet: Keine ERROR oder FATAL Meldungen

## Phase 9: Application Migration

### Connection Updates

- [ ] Alte Connection-Strings identifizieren

  ```bash
  grep -r "dev-timescale-db-0" . --include="*.yaml" --include="*.conf"
  ```

- [ ] Neue Connection-String

  ```
  Host: timescale-db-rw.hetida-platform-dev.svc.cluster.local
  Port: 5432
  Database: hetida_ts
  User: tsadmin
  ```

- [ ] Apps updaten und deployen
  - [ ] ConfigMaps/Secrets mit neuer Connection aktualisieren
  - [ ] Apps redeploy
  - [ ] Funktionalität testen

### Validierung

- [ ] Apps können sich verbinden

  ```bash
  # Test aus App-Pod
  kubectl exec -it <app-pod> -n hetida-platform-dev -- \
    nc -zv timescale-db-rw.hetida-platform-dev.svc.cluster.local 5432
  ```

- [ ] Datenbank-Operationen funktionieren
  - [ ] SELECT Queries
  - [ ] INSERT Queries
  - [ ] UPDATE/DELETE Queries

## Phase 10: Monitoring & Observability

### Grafana Dashboard

- [ ] Grafana erreichbar
- [ ] CloudNativePG Dashboard importiert
  - [ ] Dashboard: https://grafana.com/grafana/dashboards/20857
- [ ] Metriken sichtbar
- [ ] Alerts konfiguriert

### Alerts

- [ ] PrometheusRule erstellt

  ```bash
  kubectl get prometheusrule -n hetida-platform-dev
  ```

- [ ] Wichtige Alerts:
  - [ ] Primary nicht erreichbar
  - [ ] Replica out-of-sync
  - [ ] Disk voll
  - [ ] Backup fehlgeschlagen

## Phase 11: Cleanup (nach 2-4 Wochen Stabilität)

### Altes System löschen

- [ ] Altes StatefulSet skalieren auf 0

  ```bash
  kubectl scale statefulset dev-timescale-db --replicas=0 -n hetida-platform-dev
  ```

- [ ] Nach 1-2 Wochen: Alte Ressourcen löschen
  ```bash
  kubectl delete statefulset dev-timescale-db -n hetida-platform-dev
  kubectl delete svc dev-timescale-db-0 -n hetida-platform-dev
  kubectl delete pvc -n hetida-platform-dev -l app=old-timescale-db
  ```

### Archivierung

- [ ] Alte Dateien archivieren
  ```bash
  mkdir -p archived_legacy
  mv timescale-db-*.yaml archived_legacy/
  git add archived_legacy/
  ```

## 🎯 Erfolgreiche Migration = Alle Häkchen ✓

```
Phase 1: Vorbereitung       [████████] ✓
Phase 2: Operator Install   [████████] ✓
Phase 3: Deployment         [████████] ✓
Phase 4: DB Validierung     [████████] ✓
Phase 5: Replication & HA   [████████] ✓
Phase 6: Data Migration     [████████] ✓
Phase 7: Backup & Recovery  [████████] ✓
Phase 8: Monitoring         [████████] ✓
Phase 9: App Migration      [████████] ✓
Phase 10: Observability     [████████] ✓
Phase 11: Cleanup           [████████] ✓
```

## 🔗 Wichtige Befehle (Quick Reference)

```bash
# Cluster Status
kubectl get cluster timescale-db -n hetida-platform-dev -o wide

# Pods anzeigen
kubectl get pods -n hetida-platform-dev -l postgresql.cnpg.io/cluster=timescale-db

# Primary identifizieren
kubectl get pods -n hetida-platform-dev -L postgresql.cnpg.io/role

# In Cluster einsteigen
kubectl exec -it timescale-db-1 -n hetida-platform-dev -- psql -U tsadmin -d hetida_ts

# Logs
kubectl logs -f timescale-db-1 -n hetida-platform-dev

# Replication Status
psql> SELECT * FROM pg_stat_replication;

# Metriken
kubectl port-forward svc/timescale-db-monitoring 9187:9187 -n hetida-platform-dev

# Backup triggern
kubectl patch cluster timescale-db --type merge \
  -p '{"metadata":{"annotations":{"cnpg.io/backup":"true"}}}' \
  -n hetida-platform-dev
```

---

**Feedback**: Bei Problemen: siehe CLOUDNATIVEPG_MIGRATION_GUIDE.md
