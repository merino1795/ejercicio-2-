#!/usr/bin/env bash
# ==============================================================================
# Script:      agente.sh
# Autores:     Grupo 7
# Descripción: Agente ligero de monitorización de recursos del sistema. Recoge
#              CPU (/proc/stat con 2 lecturas separadas 1s), memoria
#              (/proc/meminfo), disco (df -P), carga (/proc/loadavg), uptime
#              (/proc/uptime) y top 3 procesos por CPU (ps + jq), construye el
#              JSON con tipos numéricos reales (--argjson) y lo envía al canal
#              "monitor" vía webhook cada N segundos, registrando errores en
#              agente.log.
#
# Uso:
#   ./agente.sh [opciones]
#
# Ejemplos:
#   ./agente.sh
#   ./agente.sh -i 10 -H kali-g7
#   ./agente.sh -i 5 --once --dry-run
#   ./agente.sh -w http://SERVIDOR_AULA:9007/webhook/TU_TOKEN
#
# Variables de entorno opcionales (también se leen de .env si existe):
#   WEBHOOK_URL   URL POST del webhook
#   HOST_NOMBRE   Identificador del equipo (por defecto: kali-g7)
#   HOST_MAC      Dirección MAC del equipo (por defecto: autodetectada)
#   CANAL         Canal destino (por defecto: monitor)
#   LOG_FILE      Fichero de registro de errores (por defecto: agente.log)
# ==============================================================================

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cargar_env_local() {
  local archivo clave valor
  for archivo in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../.env"; do
    [[ -f "$archivo" ]] || continue
    while IFS='=' read -r clave valor; do
      [[ -z "$clave" || "$clave" == \#* ]] && continue
      valor="${valor%$'\r'}"
      valor="${valor#\"}"
      valor="${valor%\"}"
      case "$clave" in
        WEBHOOK_URL) [[ -z "${WEBHOOK_URL:-}" ]] && WEBHOOK_URL="$valor" ;;
      esac
    done < "$archivo"
  done
}

cargar_env_local

WEBHOOK_URL="${WEBHOOK_URL:-http://SERVIDOR_AULA:9007/webhook/TU_TOKEN}"
HOST_NOMBRE="${HOST_NOMBRE:-kali-g7}"
HOST_MAC="${HOST_MAC:-}"
CANAL="${CANAL:-monitor}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/agente.log}"
INTERVALO=10
SOLO_UNA_VEZ=false
DRY_RUN=false

mostrar_uso() {
  cat <<EOF
Uso:
  $(basename "$0") [opciones]

Opciones:
  -i, --intervalo SEGUNDOS   Intervalo entre envíos en segundos (defecto: $INTERVALO)
  -H, --host NOMBRE          Nombre del host en el JSON (defecto: $HOST_NOMBRE)
  -m, --mac DIRECCION_MAC    MAC identificadora del equipo (defecto: autodetectada)
  -w, --webhook URL          URL POST del webhook (defecto: $WEBHOOK_URL)
  -c, --canal NOMBRE         Canal de publicación (defecto: $CANAL)
  -l, --log FICHERO          Fichero de log de errores (defecto: $LOG_FILE)
  -1, --once                 Recoger y enviar un único informe y salir
      --dry-run              Mostrar el JSON generado sin enviarlo por HTTP
  -h, --help                 Mostrar esta ayuda
EOF
}

comprobar_dependencias() {
  local faltan=()
  local cmd
  for cmd in jq curl awk ps df; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      faltan+=("$cmd")
    fi
  done

  if (( ${#faltan[@]} > 0 )); then
    echo "[ERROR] Faltan dependencias: ${faltan[*]}" >&2
    exit 1
  fi
}

registrar_error() {
  local mensaje="$1"
  local ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '[%s] [ERROR] %s\n' "$ts" "$mensaje" >> "$LOG_FILE"
  echo "[ERROR] $mensaje (registrado en $LOG_FILE)" >&2
}

calcular_cpu_pct() {
  # Columnas /proc/stat: cpu user nice system idle iowait irq softirq steal guest guest_nice
  local _ u1 n1 s1 i1 w1 ir1 so1 st1 _rest1
  local _2 u2 n2 s2 i2 w2 ir2 so2 st2 _rest2

  read -r _ u1 n1 s1 i1 w1 ir1 so1 st1 _rest1 < /proc/stat
  sleep 1
  read -r _2 u2 n2 s2 i2 w2 ir2 so2 st2 _rest2 < /proc/stat

  awk -v u1="$u1" -v n1="$n1" -v s1="$s1" -v i1="$i1" -v w1="$w1" -v ir1="$ir1" -v so1="$so1" -v st1="$st1" \
      -v u2="$u2" -v n2="$n2" -v s2="$s2" -v i2="$i2" -v w2="$w2" -v ir2="$ir2" -v so2="$so2" -v st2="$st2" '
    BEGIN {
      idle1 = i1 + w1
      idle2 = i2 + w2
      total1 = u1 + n1 + s1 + i1 + w1 + ir1 + so1 + st1
      total2 = u2 + n2 + s2 + i2 + w2 + ir2 + so2 + st2
      dt = total2 - total1
      di = idle2 - idle1
      if (dt <= 0) {
        printf "0.0"
      } else {
        pct = ((dt - di) * 100.0) / dt
        if (pct < 0) pct = 0
        if (pct > 100) pct = 100
        printf "%.1f", pct
      }
    }
  '
}

obtener_memoria_json() {
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      if (total <= 0) {
        printf "{\"total_mb\":0,\"usada_mb\":0,\"pct\":0.0}"
      } else {
        usada_kb = total - avail
        if (usada_kb < 0) usada_kb = 0
        total_mb = int(total / 1024)
        usada_mb = int(usada_kb / 1024)
        pct = (usada_kb * 100.0) / total
        printf "{\"total_mb\":%d,\"usada_mb\":%d,\"pct\":%.1f}", total_mb, usada_mb, pct
      }
    }
  ' /proc/meminfo
}

obtener_disco_json() {
  local salida_df
  salida_df="$(df -P -l -x tmpfs -x devtmpfs -x squashfs -x efivarfs 2>/dev/null || df -P /)"

  jq -R -s '
    split("\n")
    | .[1:]
    | map(select(length > 0))
    | map(
        try (
          capture("^\\S+\\s+[0-9]+\\s+[0-9]+\\s+[0-9]+\\s+(?<pct>[0-9]+)%\\s+(?<montaje>.+)$")
          | { montaje: .montaje, pct: (.pct | tonumber) }
        ) catch empty
      )
    | unique_by(.montaje)
    | sort_by(if .montaje == "/" then "" else .montaje end)
  ' <<< "$salida_df"
}

obtener_carga_json() {
  awk '{ printf "[%.2f,%.2f,%.2f]", $1, $2, $3 }' /proc/loadavg
}

obtener_uptime_s() {
  awk '{ printf "%d", int($1) }' /proc/uptime
}

obtener_top_procesos_json() {
  # Conversión directa con jq, sin bucles de Bash
  ps -eo pid,comm,%cpu --sort=-%cpu --no-headers | head -n 3 | jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(
        try (
          capture("^\\s*(?<pid>[0-9]+)\\s+(?<cmd>.+?)\\s+(?<cpu>[0-9]+(?:\\.[0-9]+)?)\\s*$")
          | {
              pid: (.pid | tonumber),
              cmd: .cmd,
              cpu: (.cpu | tonumber)
            }
        ) catch empty
      )
  '
}

obtener_interfaz_principal() {
  local iface=""
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  fi
  if [[ -z "$iface" ]]; then
    local ruta nombre
    for ruta in /sys/class/net/*; do
      nombre="$(basename "$ruta")"
      [[ "$nombre" == "lo" ]] && continue
      if [[ -r "$ruta/operstate" ]] && [[ "$(cat "$ruta/operstate")" == "up" ]]; then
        iface="$nombre"
        break
      fi
    done
  fi
  if [[ -z "$iface" ]]; then
    local ruta nombre
    for ruta in /sys/class/net/*; do
      nombre="$(basename "$ruta")"
      [[ "$nombre" == "lo" ]] && continue
      iface="$nombre"
      break
    done
  fi
  printf '%s' "$iface"
}

obtener_mac() {
  if [[ -n "$HOST_MAC" ]]; then
    printf '%s' "${HOST_MAC,,}"
    return 0
  fi
  local iface mac=""
  iface="$(obtener_interfaz_principal)"
  if [[ -n "$iface" && -r "/sys/class/net/$iface/address" ]]; then
    mac="$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$iface/address" | tr -d '[:space:]')"
  fi
  printf '%s' "$mac"
}

obtener_ip_local() {
  local iface ip_actual=""
  iface="$(obtener_interfaz_principal)"
  if [[ -n "$iface" ]] && command -v ip >/dev/null 2>&1; then
    ip_actual="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
  fi
  printf '%s' "$ip_actual"
}

recolectar_y_enviar() {
  echo "[PASO 1/3] Recolectando métricas del sistema (CPU 1s, memoria, disco, carga, uptime, top 3 procesos)..."

  local ts mac_addr ip_local cpu_pct mem_json disco_json carga_json uptime_s top_json payload
  cpu_pct="$(calcular_cpu_pct)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mac_addr="$(obtener_mac)"
  ip_local="$(obtener_ip_local)"
  mem_json="$(obtener_memoria_json)"
  disco_json="$(obtener_disco_json)"
  carga_json="$(obtener_carga_json)"
  uptime_s="$(obtener_uptime_s)"
  top_json="$(obtener_top_procesos_json)"

  echo "[PASO 2/3] Construyendo JSON con --argjson (números reales)..."
  payload="$(jq -n -c \
    --arg canal "$CANAL" \
    --arg host "$HOST_NOMBRE" \
    --arg mac "$mac_addr" \
    --arg ip "$ip_local" \
    --arg ts "$ts" \
    --argjson cpu_pct "$cpu_pct" \
    --argjson mem "$mem_json" \
    --argjson disco "$disco_json" \
    --argjson carga "$carga_json" \
    --argjson uptime_s "$uptime_s" \
    --argjson top_procesos "$top_json" '
    {
      canal: $canal,
      host: $host,
      mac: $mac,
      ip: $ip,
      ts: $ts,
      cpu_pct: $cpu_pct,
      mem: $mem,
      disco: $disco,
      carga: $carga,
      uptime_s: $uptime_s,
      top_procesos: $top_procesos
    }
  ')"

  if ! jq -e '.host and (.cpu_pct | type == "number") and (.mem.pct | type == "number")' >/dev/null <<< "$payload"; then
    registrar_error "JSON generado inválido: $payload"
    return 1
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] JSON generado para canal '$CANAL' ($WEBHOOK_URL):"
    jq . <<< "$payload"
    return 0
  fi

  echo "[PASO 3/3] Enviando informe de '$HOST_NOMBRE' (CPU: ${cpu_pct}%, Mem: $(jq -r '.mem.pct' <<< "$payload")%) -> $WEBHOOK_URL"
  local respuesta http_code cuerpo
  if ! respuesta="$(curl -sS --max-time 10 -w $'\n%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-Canal: $CANAL" \
    -d "$payload" \
    "$WEBHOOK_URL" 2>&1)"; then
    registrar_error "Fallo de conexión curl hacia $WEBHOOK_URL: $respuesta"
    return 1
  fi

  http_code="${respuesta##*$'\n'}"
  cuerpo="${respuesta%$'\n'*}"

  if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && ! jq -e 'has("ok") and .ok != true' >/dev/null 2>&1 <<< "$cuerpo"; then
    echo "[OK] [$ts] Enviado ($HOST_NOMBRE) -> HTTP $http_code | $cuerpo"
  else
    registrar_error "Webhook rechazó el envío (HTTP $http_code): $cuerpo"
    return 1
  fi
}

parsear_argumentos() {
  while (( $# > 0 )); do
    case "$1" in
      -i|--intervalo)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        INTERVALO="$2"
        shift 2
        ;;
      -H|--host)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        HOST_NOMBRE="$2"
        shift 2
        ;;
      -m|--mac)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        HOST_MAC="$2"
        shift 2
        ;;
      -w|--webhook)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        WEBHOOK_URL="$2"
        shift 2
        ;;
      -c|--canal)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        CANAL="$2"
        shift 2
        ;;
      -l|--log)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        LOG_FILE="$2"
        shift 2
        ;;
      -1|--once)
        SOLO_UNA_VEZ=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        mostrar_uso
        exit 0
        ;;
      *)
        echo "[ERROR] Opción desconocida: $1" >&2
        mostrar_uso >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parsear_argumentos "$@"
  comprobar_dependencias

  if [[ ! "$INTERVALO" =~ ^[0-9]+$ ]] || (( INTERVALO < 1 )); then
    echo "[ERROR] El intervalo (-i) debe ser un entero >= 1 segundo." >&2
    exit 1
  fi

  if [[ "$SOLO_UNA_VEZ" == true ]]; then
    recolectar_y_enviar
    exit 0
  fi

  SLEEP_PID=""
  detener_agente() {
    if [[ -n "$SLEEP_PID" ]]; then
      kill "$SLEEP_PID" 2>/dev/null || true
    fi
    echo ""
    echo "[INFO] Agente detenido por el usuario."
    exit 0
  }
  trap detener_agente INT TERM
  echo "[INFO] Agente iniciado para host '$HOST_NOMBRE' cada ${INTERVALO}s -> $WEBHOOK_URL (canal: $CANAL, Ctrl+C para salir)"

  local espera
  espera=$(( INTERVALO > 1 ? INTERVALO - 1 : 0 ))

  while true; do
    recolectar_y_enviar || true
    if (( espera > 0 )); then
      sleep "$espera" &
      SLEEP_PID=$!
      wait "$SLEEP_PID" || true
      SLEEP_PID=""
    fi
  done
}

main "$@"
