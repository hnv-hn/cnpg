#!/bin/bash

# CloudNativePG Migration Script für TimescaleDB
# Dieses Script automatisiert die Migration vom alten StatefulSet zum neuen CloudNativePG Cluster

set -e

NAMESPACE="hetida-platform-dev"
OLD_POD="dev-timescale-db-0"
NEW_CLUSTER="timescale-db"
NEW_POD="timescale-db-1"
DUMP_FILE="/tmp/hetida_ts_$(date +%Y%m%d_%H%M%S).dump"
DB_NAME="hetida_ts"
DB_USER="tsadmin"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funktionen
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Pre-flight checks
pre_flight_checks() {
    log_info "Führe Pre-Flight Checks durch..."
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl nicht gefunden. Bitte installieren."
        exit 1
    fi
    
    # Check namespace
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        log_error "Namespace $NAMESPACE nicht gefunden."
        exit 1
    fi
    
    # Check old pod
    if ! kubectl get pod $OLD_POD -n $NAMESPACE &> /dev/null; then
        log_error "Altes Pod $OLD_POD nicht gefunden in $NAMESPACE"
        exit 1
    fi
    
    # Check new cluster
    if ! kubectl get cluster $NEW_CLUSTER -n $NAMESPACE &> /dev/null; then
        log_warn "Neuer Cluster $NEW_CLUSTER noch nicht erstellt."
        log_info "Bitte erst CloudNativePG Ressourcen deployen:"
        log_info "  kubectl apply -k hetida-platform-kustomize/base/hetida-platform-cnpg-db -n $NAMESPACE"
        exit 1
    fi
    
    # Check if new cluster is ready
    if ! kubectl wait --for=condition=ready pod -l postgresql.cnpg.io/cluster=$NEW_CLUSTER -n $NAMESPACE --timeout=300s 2>/dev/null; then
        log_error "Neuer Cluster ist nicht ready. Bitte warten und später erneut versuchen."
        exit 1
    fi
    
    log_info "Pre-Flight Checks ✓"
}

# Step 1: Dump erstellen
create_dump() {
    log_info "Erstelle Dump aus altem System..."
    
    kubectl exec $OLD_POD -n $NAMESPACE -- \
        pg_dump -U $DB_USER -d $DB_NAME -Fc > $DUMP_FILE
    
    local size=$(du -h $DUMP_FILE | cut -f1)
    log_info "Dump erstellt: $DUMP_FILE ($size)"
}

# Step 2: Dump validieren
validate_dump() {
    log_info "Validiere Dump..."
    
    if ! file $DUMP_FILE | grep -q "pg_dump"; then
        log_error "Dump-Datei ist invalid"
        rm $DUMP_FILE
        exit 1
    fi
    
    log_info "Dump-Validierung ✓"
}

# Step 3: Dump in neues System kopieren
copy_dump() {
    log_info "Kopiere Dump in neuen Cluster..."
    
    kubectl cp $DUMP_FILE \
        $NEW_POD:/tmp/hetida_ts.dump \
        -n $NAMESPACE
    
    log_info "Dump kopiert"
}

# Step 4: Row Count vor Restore (Referenz)
get_old_row_count() {
    log_info "Ermittle Row-Count aus altem System..."
    
    OLD_COUNT=$(kubectl exec $OLD_POD -n $NAMESPACE -- \
        psql -U $DB_USER -d $DB_NAME -t -c \
        "SELECT COUNT(*) FROM timeseries;")
    
    echo $OLD_COUNT
}

# Step 5: Restore in neues System
restore_dump() {
    log_info "Starte Restore in neuen Cluster..."
    log_warn "Dies kann 10-60 Minuten dauern, abhängig von der Datenmenge..."
    
    kubectl exec $NEW_POD -n $NAMESPACE -- \
        pg_restore -U $DB_USER -d $DB_NAME -Fc /tmp/hetida_ts.dump --clean
    
    log_info "Restore abgeschlossen"
}

# Step 6: Row Count nach Restore (Validierung)
get_new_row_count() {
    log_info "Ermittle Row-Count aus neuem System..."
    
    NEW_COUNT=$(kubectl exec $NEW_POD -n $NAMESPACE -- \
        psql -U $DB_USER -d $DB_NAME -t -c \
        "SELECT COUNT(*) FROM timeseries;")
    
    echo $NEW_COUNT
}

# Step 7: Validate
validate_migration() {
    log_info "Validiere Migration..."
    
    local old_count=$1
    local new_count=$2
    
    if [ "$old_count" -eq "$new_count" ]; then
        log_info "Row-Count Match: $old_count rows ✓"
    else
        log_error "Row-Count Mismatch!"
        log_error "  Alt: $old_count"
        log_error "  Neu: $new_count"
        return 1
    fi
    
    # Check Extensions
    log_info "Prüfe TimescaleDB Extensions..."
    kubectl exec $NEW_POD -n $NAMESPACE -- \
        psql -U $DB_USER -d $DB_NAME -c "\dx" > /dev/null
    
    log_info "Extension-Prüfung ✓"
    
    # Check Hypertables
    log_info "Prüfe Hypertables..."
    local hypertables=$(kubectl exec $NEW_POD -n $NAMESPACE -- \
        psql -U $DB_USER -d $DB_NAME -t -c \
        "SELECT COUNT(*) FROM timescaledb_information.hypertables;")
    
    if [ "$hypertables" -gt 0 ]; then
        log_info "Hypertables gefunden: $hypertables ✓"
    else
        log_warn "Keine Hypertables gefunden - manuell nachchecken!"
    fi
}

# Step 8: Cleanup
cleanup() {
    log_info "Räume auf..."
    
    kubectl exec $NEW_POD -n $NAMESPACE -- \
        rm /tmp/hetida_ts.dump 2>/dev/null || true
    
    rm $DUMP_FILE
    
    log_info "Cleanup abgeschlossen"
}

# Step 9: Post-Migration Instructions
post_migration() {
    cat <<EOF

${GREEN}=== MIGRATION ERFOLGREICH ===${NC}

Nächste Schritte:

1. ${YELLOW}Teste Verbindung zum neuen Cluster:${NC}
   kubectl exec -it $NEW_POD -n $NAMESPACE -- psql -U $DB_USER -d $DB_NAME

2. ${YELLOW}Update Applications:${NC}
   - ConnectionString zu: $NEW_CLUSTER-rw.$NAMESPACE.svc.cluster.local:5432
   - Oder: timescale-db-rw (interner DNS im Cluster)

3. ${YELLOW}Monitor neue Datenbank:${NC}
   kubectl logs -f $NEW_POD -n $NAMESPACE

4. ${YELLOW}Backup testen:${NC}
   kubectl get backups -n $NAMESPACE

5. ${YELLOW}Altes System deaktivieren:${NC}
   kubectl scale statefulset dev-timescale-db --replicas=0 -n $NAMESPACE

6. ${YELLOW}Nach erfolgreicher Migration (2-4 Wochen Beobachtung):${NC}
   kubectl delete statefulset dev-timescale-db -n $NAMESPACE
   kubectl delete pvc -n $NAMESPACE -l app=timescale-db

EOF
}

# Hauptprogramm
main() {
    log_info "Starte CloudNativePG Migration für TimescaleDB"
    log_info "================================================"
    
    pre_flight_checks
    
    log_info ""
    log_warn "Migration wird gestartet."
    log_warn "Dies wird die Datenbank kurzzeitig belasten."
    read -p "Fortfahren? (ja/nein): " confirm
    if [ "$confirm" != "ja" ]; then
        log_info "Migration abgebrochen."
        exit 0
    fi
    
    create_dump
    validate_dump
    old_count=$(get_old_row_count)
    copy_dump
    restore_dump
    new_count=$(get_new_row_count)
    validate_migration "$old_count" "$new_count" || exit 1
    cleanup
    post_migration
}

# Error Handler
trap 'log_error "Script abgebrochen"; exit 1' INT TERM

# Start
main "$@"
