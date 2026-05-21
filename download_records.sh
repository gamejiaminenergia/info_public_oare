#!/usr/bin/env bash
# =============================================================================
# download_records.sh
# Descarga los records de cada endpoint SIMEM para un rango de fechas,
# un día a la vez (la API solo acepta startDate == endDate).
#
# Características para uso por IA:
#   - Salida estructurada y predecible
#   - Manejo robusto de errores
#   - Opciones de modo seco y salida JSON
#   - Validación completa de Entradas
#
# Uso:
#   ./download_records.sh <fecha_inicio> <fecha_fin> [archivo_csv] [id_dataset] [output_dir]
#   ./download_records.sh --help
#
# Opciones:
#   --help      Muestra esta ayuda y sale
#   --dry-run   Muestra qué se haría sin ejecutar descargas
#   --quiet     Minimiza la salida (solo errores)
#   --json      Salida de progreso en formato JSON (para consumo por máquinas)
#
# Ejemplos:
#   ./download_records.sh 2026-05-01 2026-05-10
#   ./download_records.sh 2026-05-01 2026-05-10 api_simem.csv
#   ./download_records.sh 2026-05-01 2026-05-10 api_simem.csv 12345
#   ./download_records.sh 2026-05-01 2026-05-10 api_simem.csv 12345 test
#
# Salida:
#   <output_dir>/<IdDataset>/<IdDataset>_<YYYY-MM-DD>.json
# =============================================================================

set -euo pipefail

# ── Colores para log ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# Funciones de logging adaptadas para uso por IA
log_info()  { if [[ "$QUIET" == "false" && "$OUTPUT_JSON" == "false" ]]; then echo -e "${CYAN}[INFO]${RESET}  $*"; fi; }
log_ok()    { if [[ "$QUIET" == "false" && "$OUTPUT_JSON" == "false" ]]; then echo -e "${GREEN}[ OK ]${RESET}  $*"; fi; }
log_warn()  { if [[ "$QUIET" == "false" && "$OUTPUT_JSON" == "false" ]]; then echo -e "${YELLOW}[WARN]${RESET}  $*"; fi; }
log_error() { echo -e "${RED}[ERR ]${RESET}  $*" >&2; }  # Los errores siempre se muestran

# Funciones para salida JSON (para consumo por máquinas)
json_log() {
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    echo "$1" | jq -c . 2>/dev/null || echo "$1"
  fi
}

# ── Validar dependencias ────────────────────────────────────────────────────
for cmd in curl jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    log_error "Dependencia faltante: '$cmd'. Instálela antes de continuar."
    exit 1
  fi
done

# ── Argumentos ──────────────────────────────────────────────────────────────
# Opciones por defecto
DRY_RUN=false
QUIET=false
OUTPUT_JSON=false

# Procesar opciones
while [[ $# -gt 0 ]]; do
  case $1 in
    --help)
      echo -e "${BOLD}Uso:${RESET} $0 <fecha_inicio> <fecha_fin> [csv_path] [id_dataset] [output_dir]"
      echo ""
      echo "Opciones:"
      echo "  --help      Muestra esta ayuda y sale"
      echo "  --dry-run   Muestra qué se haría sin ejecutar descargas"
      echo "  --quiet     Minimiza la salida (solo errores)"
      echo "  --json      Salida de progreso en formato JSON (para consumo por máquinas)"
      echo ""
      echo "Ejemplos:"
      echo "  $0 2026-05-01 2026-05-10"
      echo "  $0 2026-05-01 2026-05-10 api_simem.csv"
      echo "  $0 2026-05-01 2026-05-10 api_simem.csv 12345"
      echo "  $0 2026-05-01 2026-05-10 api_simem.csv 12345 test"
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --json)
      OUTPUT_JSON=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -lt 2 ]]; then
  echo -e "${BOLD}Uso:${RESET} $0 <fecha_inicio> <fecha_fin> [csv_path] [id_dataset] [output_dir] [--options]"
  echo -e "Ejemplo: $0 2026-05-01 2026-05-10 api_simem.csv 12345"
  echo -e "Ejemplo: $0 2026-05-01 2026-05-10 api_simem.csv 12345 test"
  echo -e "Pruebe '$0 --help' para más información"
  exit 1
fi

DATE_START="$1"
DATE_END="$2"
CSV_FILE="${3:-api_simem.csv}"
DATASET_FILTER="${4:-}"   # opcional: si se proporciona, solo descarga ese IdDataset
OUTPUT_DIR="${5:-records}"  # opcional: directorio de salida (por defecto: records)

# ── Validar formato de fechas ───────────────────────────────────────────────
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
if [[ ! "$DATE_START" =~ $date_re ]] || [[ ! "$DATE_END" =~ $date_re ]]; then
  log_error "Fechas deben tener formato YYYY-MM-DD"
  exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
  log_error "No se encontró el archivo: $CSV_FILE"
  exit 1
fi

# ── Configuración ───────────────────────────────────────────────────────────
BASE_URL="https://www.simem.co/backend-files/api/PublicData"
RECORDS_DIR="${OUTPUT_DIR}"  # Directorio de salida configurable
DELAY=0.3          # segundos entre requests
MAX_RETRIES=3      # reintentos ante fallo
RETRY_WAIT=5       # segundos entre reintentos
LOG_FILE="descarga_records.log"

# ── Utilidad: sumar días compatible con Linux y macOS ───────────────────────
date_add_day() {
  local d="$1"
  if date --version &>/dev/null 2>&1; then
    date -d "$d + 1 day" +%Y-%m-%d
  else
    date -j -v+1d -f "%Y-%m-%d" "$d" +%Y-%m-%d
  fi
}

date_to_epoch() {
  local d="$1"
  if date --version &>/dev/null 2>&1; then
    date -d "$d" +%s
  else
    date -j -f "%Y-%m-%d" "$d" +%s
  fi
}

# ── Generar lista de fechas ─────────────────────────────────────────────────
build_date_list() {
  local start="$1" end="$2"
  local current="$start"
  local dates=()
  local epoch_end
  epoch_end=$(date_to_epoch "$end")

  while true; do
    local epoch_cur
    epoch_cur=$(date_to_epoch "$current")
    [[ $epoch_cur -gt $epoch_end ]] && break
    dates+=("$current")
    current=$(date_add_day "$current")
  done
  echo "${dates[@]}"
}

# ── Leer CSV (saltando header) y filtrar por IdDataset si se especifica ──────
# Devuelve líneas "IdDataset|dataset_name"
read_csv() {
  python3 - "$CSV_FILE" "$DATASET_FILTER" << 'PYEOF'
import csv, sys
csv_file = sys.argv[1]
filter_id = sys.argv[2] if len(sys.argv) > 2 else ""

with open(csv_file, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        did = row.get("IdDataset", "").strip()
        name = row.get("dataset", "").strip().replace("|", "_")
        if not did:
            continue
        if filter_id and did != filter_id:
            continue
        print(f"{did}|{name}")
PYEOF
}

# ── Descargar un día/endpoint y extraer solo records ───────────────────────
download_day() {
  local dataset_id="$1"
  local query_date="$2"
  local out_file="$3"

  local url="${BASE_URL}?startDate=${query_date}&endDate=${query_date}&datasetId=${dataset_id}"

  for attempt in $(seq 1 $MAX_RETRIES); do
    http_code=$(curl -s -o /tmp/simem_tmp.json -w "%{http_code}" \
      --max-time 30 \
      --compressed \
      -H "Accept: application/json" \
      "$url" 2>/dev/null)

    if [[ "$http_code" == "200" ]]; then
      local record_count
      record_count=$(jq -r '
        (.result.records // .result.data // .records // []) | length
      ' /tmp/simem_tmp.json 2>/dev/null || echo "0")

      if [[ "$record_count" == "0" ]]; then
        echo "[]" > "$out_file"
      else
        jq -c '
          .result.records // .result.data // .records // []
        ' /tmp/simem_tmp.json > "$out_file"
      fi

      echo "$record_count"
      return 0

    elif [[ "$http_code" == "404" ]]; then
      echo "[]" > "$out_file"
      echo "0"
      return 0

    else
      if [[ $attempt -lt $MAX_RETRIES ]]; then
        sleep $RETRY_WAIT
      fi
    fi
  done

  echo "ERROR"
  return 1
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  # Si es modo dry-run, mostrar qué se haría y salir
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "MODO SECO: Se descargarían los siguientes archivos:"
    
    # Leer endpoints (con filtro opcional)
    mapfile -t ENDPOINTS < <(read_csv)
    local n_endpoints=${#ENDPOINTS[@]}
    
    if [[ $n_endpoints -eq 0 ]]; then
      if [[ -n "$DATASET_FILTER" ]]; then
        log_error "No se encontró el IdDataset '$DATASET_FILTER' en $CSV_FILE"
      else
        log_error "No se encontraron endpoints en $CSV_FILE"
      fi
      exit 1
    fi
    
    # Construir lista de fechas
    read -ra DATES <<< "$(build_date_list "$DATE_START" "$DATE_END")"
    local n_dates=${#DATES[@]}
    
    for endpoint_line in "${ENDPOINTS[@]}"; do
      local dataset_id="${endpoint_line%%|*}"
      local dataset_name="${endpoint_line##*|}"
      local ep_dir="${RECORDS_DIR}/${dataset_id}"
      
      for query_date in "${DATES[@]}"; do
        local out_file="${ep_dir}/${dataset_id}_${query_date}.json"
        echo "${out_file}"
      done
    done
    return 0
  fi
  
  # Ejecución normal (no dry-run)
  echo "" | tee "$LOG_FILE"
  echo -e "${BOLD}═══════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}  SIMEM — Descarga de Records por Rango${RESET}"     | tee -a "$LOG_FILE"
  echo -e "${BOLD}═══════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "  Rango  : ${BOLD}${DATE_START}${RESET} → ${BOLD}${DATE_END}${RESET}" | tee -a "$LOG_FILE"
  echo -e "  CSV    : ${CSV_FILE}"                                               | tee -a "$LOG_FILE"
  if [[ -n "$DATASET_FILTER" ]]; then
    echo -e "  Filtro : Solo IdDataset = ${BOLD}${DATASET_FILTER}${RESET}"         | tee -a "$LOG_FILE"
  else
    echo -e "  Filtro : Todos los datasets"                                        | tee -a "$LOG_FILE"
  fi
  echo -e "  Salida : ${RECORDS_DIR}/<IdDataset>/<IdDataset>_<fecha>.json\n"    | tee -a "$LOG_FILE"

  # Leer endpoints (con filtro opcional)
  mapfile -t ENDPOINTS < <(read_csv)
  local n_endpoints=${#ENDPOINTS[@]}

  if [[ $n_endpoints -eq 0 ]]; then
    if [[ -n "$DATASET_FILTER" ]]; then
      log_error "No se encontró el IdDataset '$DATASET_FILTER' en $CSV_FILE"
    else
      log_error "No se encontraron endpoints en $CSV_FILE"
    fi
    exit 1
  fi

  # Construir lista de fechas
  read -ra DATES <<< "$(build_date_list "$DATE_START" "$DATE_END")"
  local n_dates=${#DATES[@]}

  log_info "Endpoints : $n_endpoints"
  log_info "Días      : $n_dates  (${DATES[0]} → ${DATES[-1]})"
  log_info "Total req.: $((n_endpoints * n_dates))"
  echo ""

  local total_ok=0 total_skip=0 total_err=0
  local ep_idx=0

  for endpoint_line in "${ENDPOINTS[@]}"; do
    ep_idx=$((ep_idx + 1))
    local dataset_id="${endpoint_line%%|*}"
    local dataset_name="${endpoint_line##*|}"

    local ep_dir="${RECORDS_DIR}/${dataset_id}"
    mkdir -p "$ep_dir"

    # Salida de progreso (normal o JSON)
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      json_log "{\"event\":\"dataset_start\",\"dataset_id\":\"$dataset_id\",\"dataset_name\":\"$dataset_name\",\"index\":$ep_idx,\"total\":$n_endpoints}"
    else
      echo -e "${BOLD}[${ep_idx}/${n_endpoints}]${RESET} ${dataset_id} — ${dataset_name}" | tee -a "$LOG_FILE"
    fi

    local day_idx=0
    for query_date in "${DATES[@]}"; do
      day_idx=$((day_idx + 1))
      local out_file="${ep_dir}/${dataset_id}_${query_date}.json"

      if [[ -f "$out_file" ]]; then
        if [[ "$OUTPUT_JSON" == "true" ]]; then
          json_log "{\"event\":\"file_skip\",\"dataset_id\":\"$dataset_id\",\"date\":\"$query_date\",\"file\":\"$out_file\"}"
        else
          echo -e "  ${YELLOW}↷${RESET} ${query_date} ya existe" | tee -a "$LOG_FILE"
        fi
        total_skip=$((total_skip + 1))
        continue
      fi

      local result
      result=$(download_day "$dataset_id" "$query_date" "$out_file")

      if [[ "$result" == "ERROR" ]]; then
        if [[ "$OUTPUT_JSON" == "true" ]]; then
          json_log "{\"event\":\"download_error\",\"dataset_id\":\"$dataset_id\",\"date\":\"$query_date\",\"file\":\"$out_file\"}"
        else
          echo -e "  ${RED}✗${RESET} ${query_date} — fallo tras $MAX_RETRIES intentos" | tee -a "$LOG_FILE"
        fi
        total_err=$((total_err + 1))
      else
        if [[ "$OUTPUT_JSON" == "true" ]]; then
          json_log "{\"event\":\"download_success\",\"dataset_id\":\"$dataset_id\",\"date\":\"$query_date\",\"file\":\"$out_file\",\"records\":$result}"
        else
          echo -e "  ${GREEN}✓${RESET} ${query_date} — ${result} records" | tee -a "$LOG_FILE"
        fi
        total_ok=$((total_ok + 1))
      fi

      sleep "$DELAY"
    done
    
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      json_log "{\"event\":\"dataset_end\",\"dataset_id\":\"$dataset_id\"}"
    else
      echo "" | tee -a "$LOG_FILE"
    fi
  done

  # Resumen final
  echo -e "${BOLD}═══════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}  Resumen${RESET}"                                       | tee -a "$LOG_FILE"
  echo -e "${BOLD}═══════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    json_log "{\"event\":\"summary\",\"ok\":$total_ok,\"skipped\":$total_skip,\"errors\":$total_err}"
  else
    echo -e "  ${GREEN}OK${RESET}      : $total_ok"     | tee -a "$LOG_FILE"
    echo -e "  ${YELLOW}Saltados${RESET}: $total_skip"   | tee -a "$LOG_FILE"
    echo -e "  ${RED}Errores${RESET} : $total_err"      | tee -a "$LOG_FILE"
    echo -e "  Log     : $LOG_FILE"                     | tee -a "$LOG_FILE"
  fi
  
  echo ""
}

main