#!/usr/bin/env bash
# ==============================================================================
# Script:      panel.sh
# Autores:     Grupo 7
# Descripción: Consulta periódicamente el canal "monitor" (GET /sync), agrupa
#              por host quedándose con el último informe, dibuja un panel en
#              tiempo real con colores por umbral y marca como CAÍDO cualquier
#              equipo sin reportes recientes (>30s).
#
# Ampliaciones incluidas (Fase 2):
#   1. Panel web (--html): genera index.html con Bash heredoc + jq -r (@html)
#      y autorrecarga cada 5s (opcionalmente servido con --servir [puerto]).
#   2. Alertas en canal "alertas": publica JSON SOLO cuando un host cambia de
#      estado (OK / AVISO / CRITICO / CAIDO), evitando spam repetitivo.
#   3. Mini-gráfica de CPU de los últimos 20 informes con ▁▂▃▄▅▆▇█.
#   4. Umbrales configurables en umbrales.json leídos con jq.
#
# Uso:
#   ./panel.sh [opciones]
#
# Ejemplos:
#   ./panel.sh
#   ./panel.sh --html
#   ./panel.sh --html --servir 8080
#   ./panel.sh --once --dry-run
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
        SYNC_URL)    [[ -z "${SYNC_URL:-}" ]] && SYNC_URL="$valor" ;;
      esac
    done < "$archivo"
  done
}

cargar_env_local

SYNC_URL="${SYNC_URL:-http://SERVIDOR_AULA:8087/sync}"
WEBHOOK_URL="${WEBHOOK_URL:-http://SERVIDOR_AULA:9007/webhook/TU_TOKEN}"
CANAL="${CANAL:-monitor}"
CANAL_ALERTAS="${CANAL_ALERTAS:-alertas}"
UMBRALES_FILE="${UMBRALES_FILE:-$SCRIPT_DIR/umbrales.json}"
HTML_FILE="${HTML_FILE:-$SCRIPT_DIR/index.html}"
ESTADO_FILE="${ESTADO_FILE:-$SCRIPT_DIR/.estado_panel.json}"

INTERVALO=5
MODO_HTML=false
SERVIR_HTTP=false
PUERTO_HTTP=8080
ENVIAR_ALERTAS=true
SOLO_UNA_VEZ=false
DRY_RUN=false
DESDE_ARCHIVO=""
HTTP_PID=""

# Valores por defecto si no existe umbrales.json
UMBRAL_AVISO=60
UMBRAL_CRITICO=85
UMBRAL_CAIDO_S=30
UMBRAL_EXPIRAR_S=0
EXPIRAR_CLI=""
HISTORIAL_GRAFICA=20

# Códigos ANSI
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_VERDE=$'\033[32m'
C_AMARILLO=$'\033[33m'
C_ROJO=$'\033[31m'
C_ROJO_BOLD=$'\033[1;31m'
C_CIAN=$'\033[36m'
C_GRIS=$'\033[90m'

mostrar_uso() {
  cat <<EOF
Uso:
  $(basename "$0") [opciones]

Opciones:
  -i, --intervalo SEGUNDOS    Intervalo de refresco en segundos (defecto: $INTERVALO)
  -s, --sync URL              URL GET de consulta (defecto: $SYNC_URL)
  -w, --webhook URL           URL POST para alertas (defecto: $WEBHOOK_URL)
  -u, --umbrales FICHERO      Fichero umbrales.json (defecto: $UMBRALES_FILE)
      --expirar SEGUNDOS      Ocultar equipos sin informes tras N seg (0 = no ocultar)
      --html [FICHERO]        Generar panel web HTML con autorrecarga (defecto: $HTML_FILE)
      --servir [PUERTO]       Servir el panel web con python3 -m http.server (defecto: $PUERTO_HTTP)
      --sin-alertas           Desactivar publicación en el canal '$CANAL_ALERTAS'
  -1, --once                  Ejecutar una sola actualización y salir
      --dry-run               No enviar alertas reales (mostrar por pantalla)
      --desde-archivo FILE    Leer respuesta /sync desde un fichero JSON local (pruebas)
  -h, --help                  Mostrar esta ayuda
EOF
}

comprobar_dependencias() {
  local faltan=()
  local cmd
  for cmd in jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      faltan+=("$cmd")
    fi
  done

  if [[ "$SERVIR_HTTP" == true ]] && ! command -v python3 >/dev/null 2>&1; then
    faltan+=("python3")
  fi

  if (( ${#faltan[@]} > 0 )); then
    echo "[ERROR] Faltan dependencias: ${faltan[*]}" >&2
    exit 1
  fi
}

cargar_umbrales() {
  if [[ -f "$UMBRALES_FILE" ]] && jq -e . "$UMBRALES_FILE" >/dev/null 2>&1; then
    UMBRAL_AVISO="$(jq -r '.aviso // 60' "$UMBRALES_FILE")"
    UMBRAL_CRITICO="$(jq -r '.critico // 85' "$UMBRALES_FILE")"
    UMBRAL_CAIDO_S="$(jq -r '.caido_s // 30' "$UMBRALES_FILE")"
    UMBRAL_EXPIRAR_S="$(jq -r '.expirar_s // 0' "$UMBRALES_FILE")"
    HISTORIAL_GRAFICA="$(jq -r '.historial_grafica // 20' "$UMBRALES_FILE")"
  fi
  if [[ -n "$EXPIRAR_CLI" ]]; then
    UMBRAL_EXPIRAR_S="$EXPIRAR_CLI"
  fi
}

color_por_pct() {
  local pct="$1"
  awk -v p="$pct" -v aviso="$UMBRAL_AVISO" -v crit="$UMBRAL_CRITICO" \
      -v v="$C_VERDE" -v a="$C_AMARILLO" -v r="$C_ROJO" '
    BEGIN {
      if (p + 0 > crit + 0) printf "%s", r
      else if (p + 0 >= aviso + 0) printf "%s", a
      else printf "%s", v
    }
  '
}

obtener_resumen_hosts_json() {
  local raw_json="$1"
  local ahora_epoch="$2"

  # Compatible tanto con mensajes a nivel raíz (.messages[].host)
  # como con mensajes envueltos en .datos (.datos.host).
  # Identifica cada equipo por su MAC (si existe), enlazando informes previos
  # del mismo host para no duplicar dispositivos cuando cambia la IP dinámica.
  jq \
    --arg canal "$CANAL" \
    --argjson ahora "$ahora_epoch" \
    --argjson aviso "$UMBRAL_AVISO" \
    --argjson critico "$UMBRAL_CRITICO" \
    --argjson caido_s "$UMBRAL_CAIDO_S" \
    --argjson expirar_s "$UMBRAL_EXPIRAR_S" \
    --argjson max_hist "$HISTORIAL_GRAFICA" '
    def a_epoch:
      if . == null or . == "" then 0
      else (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0)
      end;

    def sparkline($vals):
      ["▁","▂","▃","▄","▅","▆","▇","█"] as $bars
      | ($vals[-$max_hist:]
         | map(
             (if . < 0 then 0 elif . > 100 then 100 else . end) as $v
             | (($v / 100 * 7) | floor) as $idx
             | $bars[$idx]
           )
         | join(""));

    (if type == "object" and has("messages") then .messages
     elif type == "array" then .
     else [] end)
    | map(
        (if has("datos") and (.datos | type == "object") then .datos else . end) as $d
        | {
            _id: (._id // 0),
            canal: (.canal // $d.canal // ""),
            recibido: (._recibido // ""),
            datos: $d
          }
      )
    | map(select(
        (.canal == $canal)
        and (.datos.host != null)
        and (.datos.cpu_pct != null)
      ))
    | (map(select((.datos.mac // "") != ""))
       | sort_by([(.datos.ts // .recibido), ._id])
       | map({key: .datos.host, value: (.datos.mac | ascii_downcase)})
       | from_entries) as $host2mac
    | map(
        ((.datos.mac // $host2mac[.datos.host] // "") | ascii_downcase) as $mac_norm
        | . + {
            disp_mac: $mac_norm,
            disp_id: (if $mac_norm != "" then $mac_norm else .datos.host end)
          }
      )
    | group_by(.disp_id)
    | map(
        sort_by([(.datos.ts // .recibido), ._id])
        | (last) as $ult
        | (map(.datos.cpu_pct | tonumber)) as $hist_cpu
        | (($ult.datos.ts // $ult.recibido) | a_epoch) as $ts_ep
        | (($ult.recibido | a_epoch)) as $rec_ep
        | (if $rec_ep > 0 then $rec_ep else $ts_ep end) as $ref_ep
        | (if $ref_ep > 0 then ($ahora - $ref_ep) else 999999 end) as $edad_raw
        | (if $edad_raw < 0 then 0 else $edad_raw end) as $edad
        | (($ult.datos.disco // []) | (map(select(.montaje == "/")) | first) // first // {montaje: "/", pct: 0}) as $raiz
        | ($ult.datos.cpu_pct | tonumber) as $cpu
        | (($ult.datos.mem.pct // 0) | tonumber) as $mem_pct
        | (($raiz.pct // 0) | tonumber) as $disco_pct
        | (if $edad > $caido_s then "CAIDO"
           elif ($cpu > $critico or $mem_pct > $critico or $disco_pct > $critico) then "CRITICO"
           elif ($cpu >= $aviso or $mem_pct >= $aviso or $disco_pct >= $aviso) then "AVISO"
           else "OK"
           end) as $estado
        | (
            if $edad > $caido_s then "Sin informes hace \($edad)s (> \($caido_s)s)"
            else
              ([
                (if $cpu > $critico then "CPU \($cpu)% (> \($critico)%)"
                 elif $cpu >= $aviso then "CPU \($cpu)% (>= \($aviso)%)" else empty end),
                (if $mem_pct > $critico then "MEM \($mem_pct)% (> \($critico)%)"
                 elif $mem_pct >= $aviso then "MEM \($mem_pct)% (>= \($aviso)%)" else empty end),
                (if $disco_pct > $critico then "DISCO \($disco_pct)% (> \($critico)%)"
                 elif $disco_pct >= $aviso then "DISCO \($disco_pct)% (>= \($aviso)%)" else empty end)
              ] | if length > 0 then join(", ") else "Todos los recursos dentro de umbrales" end)
            end
          ) as $motivo
        | {
            id: $ult.disp_id,
            host: $ult.datos.host,
            mac: (if $ult.disp_mac != "" then $ult.disp_mac else "-" end),
            ip: ($ult.datos.ip // "-"),
            ts: ($ult.datos.ts // $ult.recibido // "-"),
            edad_s: $edad,
            estado: $estado,
            motivo: $motivo,
            cpu_pct: $cpu,
            grafica_cpu: sparkline($hist_cpu),
            hist_cpu: ($hist_cpu[-$max_hist:]),
            mem_pct: $mem_pct,
            mem_usada_mb: ($ult.datos.mem.usada_mb // 0),
            mem_total_mb: ($ult.datos.mem.total_mb // 0),
            disco_pct: $disco_pct,
            carga: (($ult.datos.carga // [0, 0, 0]) | map(tostring) | join(" ")),
            uptime_s: ($ult.datos.uptime_s // 0),
            top_proc: (
              (($ult.datos.top_procesos // []) | first) as $p
              | if $p == null then "-" else "\($p.cmd) (\($p.cpu)%)" end
            )
          }
      )
    | map(select($expirar_s <= 0 or .edad_s <= $expirar_s))
    | sort_by(.host, .mac)
  ' <<< "$raw_json"
}

dibujar_panel_terminal() {
  local resumen_json="$1"
  local hora_actual="$2"
  local total_hosts
  total_hosts="$(jq 'length' <<< "$resumen_json")"

  if [[ -t 1 ]]; then
    if command -v tput >/dev/null 2>&1; then
      tput clear 2>/dev/null || clear 2>/dev/null || true
      tput cup 0 0 2>/dev/null || true
    else
      clear 2>/dev/null || true
    fi
  fi

  printf '%s==================================================================================================================%s\n' "$C_CIAN" "$C_RESET"
  printf '%s PANEL DE MONITORIZACIÓN — GRUPO 7 (canal: %s)%s  |  Actualizado: %s UTC  |  Equipos: %s\n' \
    "$C_BOLD" "$CANAL" "$C_RESET" "$hora_actual" "$total_hosts"
  printf ' Umbrales: %s<%s%% OK%s | %s%s-%s%% AVISO%s | %s>%s%% CRÍTICO%s | %s>%ss CAÍDO%s\n' \
    "$C_VERDE" "$UMBRAL_AVISO" "$C_RESET" \
    "$C_AMARILLO" "$UMBRAL_AVISO" "$UMBRAL_CRITICO" "$C_RESET" \
    "$C_ROJO" "$UMBRAL_CRITICO" "$C_RESET" \
    "$C_ROJO_BOLD" "$UMBRAL_CAIDO_S" "$C_RESET"
  printf '%s==================================================================================================================%s\n' "$C_CIAN" "$C_RESET"

  if (( total_hosts == 0 )); then
    printf '\n  %sEsperando informes en el canal "%s" (%s)...%s\n\n' "$C_GRIS" "$CANAL" "$SYNC_URL" "$C_RESET"
    return 0
  fi

  printf '%s%-14s %-18s %-9s %-7s %-20s %-18s %-7s %-16s %-18s %-14s%s\n' \
    "$C_BOLD" "HOST" "MAC" "ESTADO" "CPU" "HISTORIAL (20)" "MEMORIA" "DISCO/" "CARGA (1/5/15)" "TOP PROCESO" "ÚLTIMO" "$C_RESET"
  printf '%s------------------------------------------------------------------------------------------------------------------------------------%s\n' "$C_GRIS" "$C_RESET"

  local host mac estado cpu grafica mem_pct mem_u mem_t disco carga top_proc ts edad
  while IFS=$'\t' read -r host mac estado cpu grafica mem_pct mem_u mem_t disco carga top_proc ts edad; do
    local c_est c_cpu c_mem c_dsk hora_corta mem_txt est_pad
    case "$estado" in
      CAIDO)   c_est="$C_ROJO_BOLD"; est_pad="CAÍDO    " ;;
      CRITICO) c_est="$C_ROJO_BOLD"; est_pad="CRÍTICO  " ;;
      AVISO)   c_est="$C_AMARILLO";  est_pad="AVISO    " ;;
      *)       c_est="$C_VERDE";     est_pad="OK       " ;;
    esac

    c_cpu="$(color_por_pct "$cpu")"
    c_mem="$(color_por_pct "$mem_pct")"
    c_dsk="$(color_por_pct "$disco")"

    hora_corta="${ts#*T}"
    hora_corta="${hora_corta%Z}"
    mem_txt="${mem_pct}% (${mem_u}/${mem_t}M)"

    printf '%-14s %-18s %s%s%s %s%5.1f%%%s  %s %s%-18s%s %s%5d%%%s  %-16s %-18s %s (%ss)\n' \
      "${host:0:14}" \
      "${mac:0:18}" \
      "$c_est" "$est_pad" "$C_RESET" \
      "$c_cpu" "$cpu" "$C_RESET" \
      "$grafica" \
      "$c_mem" "${mem_txt:0:18}" "$C_RESET" \
      "$c_dsk" "$disco" "$C_RESET" \
      "${carga:0:16}" \
      "${top_proc:0:18}" \
      "$hora_corta" "$edad"
  done < <(jq -r --argjson w "$HISTORIAL_GRAFICA" '
    .[]
    | (.grafica_cpu | length) as $gl
    | (.grafica_cpu + (" " * (if $w > $gl then ($w - $gl) else 0 end))) as $gpad
    | [.host, .mac, .estado, .cpu_pct, $gpad, .mem_pct, .mem_usada_mb, .mem_total_mb, .disco_pct, .carga, .top_proc, .ts, .edad_s]
    | @tsv
  ' <<< "$resumen_json")

  printf '%s------------------------------------------------------------------------------------------------------------------%s\n' "$C_GRIS" "$C_RESET"
  if [[ "$MODO_HTML" == true ]]; then
    printf ' Panel web actualizado: %s' "$HTML_FILE"
    if [[ "$SERVIR_HTTP" == true ]]; then
      printf '  (http://0.0.0.0:%s/)' "$PUERTO_HTTP"
    fi
    printf '\n'
  fi
}

evaluar_y_enviar_alertas() {
  local resumen_json="$1"
  local ts_now="$2"

  if [[ "$ENVIAR_ALERTAS" != true ]]; then
    return 0
  fi

  local estados_previos="{}"
  if [[ -f "$ESTADO_FILE" ]] && jq -e 'type == "object"' "$ESTADO_FILE" >/dev/null 2>&1; then
    estados_previos="$(cat "$ESTADO_FILE")"
  fi

  local cambios_alertas
  cambios_alertas="$(jq -c \
    --argjson prev "$estados_previos" \
    --arg canal "$CANAL_ALERTAS" \
    --arg ts "$ts_now" '
    map(
      ($prev[.id] // $prev[.host] // "OK") as $ant
      | select(.estado != $ant)
      | {
          canal: $canal,
          tipo: "alerta_recurso",
          id: .id,
          host: .host,
          mac: .mac,
          ip: .ip,
          ts: $ts,
          estado_anterior: $ant,
          estado_actual: .estado,
          motivo: .motivo,
          cpu_pct: .cpu_pct,
          mem_pct: .mem_pct,
          disco_pct: .disco_pct
        }
    )
  ' <<< "$resumen_json")"

  local alerta
  while IFS= read -r alerta; do
    [[ -z "$alerta" ]] && continue
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN][ALERTA] Cambio de estado -> $WEBHOOK_URL:"
      jq . <<< "$alerta"
    else
      local resp code
      if resp="$(curl -sS --max-time 15 -w $'\n%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-Canal: $CANAL_ALERTAS" \
        -d "$alerta" \
        "$WEBHOOK_URL" 2>&1)"; then
        code="${resp##*$'\n'}"
        echo "[ALERTA] $(jq -r '"\(.host) [\(.mac)]: \(.estado_anterior) -> \(.estado_actual) (\(.motivo))"' <<< "$alerta") [HTTP $code]"
      else
        echo "[ERROR] No se pudo enviar alerta al canal '$CANAL_ALERTAS': $resp" >&2
      fi
    fi
  done < <(jq -c '.[]' <<< "$cambios_alertas")

  # Guardar mapa de estados actual (clave por MAC/id) para detectar solo transiciones futuras
  jq 'map({key: .id, value: .estado}) | from_entries' <<< "$resumen_json" > "$ESTADO_FILE"
}

generar_panel_html() {
  local resumen_json="$1"
  local hora_actual="$2"
  local kpi_total kpi_ok kpi_alerta kpi_cpu_media cards_html filas_html

  kpi_total="$(jq 'length' <<< "$resumen_json")"
  kpi_ok="$(jq '[.[] | select(.estado == "OK")] | length' <<< "$resumen_json")"
  kpi_alerta="$(jq '[.[] | select(.estado != "OK")] | length' <<< "$resumen_json")"
  kpi_cpu_media="$(jq -r 'if length == 0 then "0.0" else ((map(.cpu_pct) | add / length * 10 | round) / 10 | tostring) end' <<< "$resumen_json")"

  cards_html="$(jq -r \
    --argjson aviso "$UMBRAL_AVISO" \
    --argjson critico "$UMBRAL_CRITICO" '
    def nivel($p):
      if $p > $critico then "crit"
      elif $p >= $aviso then "warn"
      else "ok" end;

    def nivel_est($e):
      if $e == "CAIDO" or $e == "CRITICO" then "crit"
      elif $e == "AVISO" then "warn"
      else "ok" end;

    def etiqueta_est($e):
      if $e == "CAIDO" then "CAÍDO"
      elif $e == "CRITICO" then "CRÍTICO"
      else $e end;

    def fmt_uptime($s):
      (($s / 3600) | floor) as $h
      | ((($s % 3600) / 60) | floor) as $m
      | "\($h)h \($m)m";

    def clamp($v):
      if $v < 4 then 4 elif $v > 100 then 100 else $v end;

    def prisma3d($label; $val; $txt):
      (nivel($val)) as $nv
      | (clamp($val) | tostring) as $h
      | "<div class=\"bar-col\">" +
          "<div class=\"bar-val " + $nv + "\">" + ($txt | @html) + "</div>" +
          "<div class=\"bar-well\">" +
            "<div class=\"prism prism-" + $nv + "\" style=\"--h:" + $h + "%\">" +
              "<div class=\"face front\"></div>" +
              "<div class=\"face side\"></div>" +
              "<div class=\"face top\"></div>" +
            "</div>" +
          "</div>" +
          "<div class=\"bar-lbl\">" + ($label | @html) + "</div>" +
        "</div>";

    if length == 0 then
      "<div class=\"empty-3d\">Esperando informes en el canal <strong>monitor</strong>… Ejecuta <code>./agente.sh</code> para ver los servidores en 3D.</div>"
    else
      .[] |
      (nivel_est(.estado)) as $st
      | ((.hist_cpu // [.cpu_pct]) | map(
          (nivel(.)) as $hn
          | (clamp(.) | tostring) as $hh
          | "<span class=\"h-bar h-" + $hn + "\" style=\"height:" + $hh + "%\" title=\"CPU " + (tostring | @html) + "%\"></span>"
        ) | join("")) as $hist_bars
      | "<article class=\"server-card card-" + $st + "\" data-tilt>" +
          "<div class=\"card-glare\"></div>" +
          "<header class=\"card-head\">" +
            "<div class=\"host-id\">" +
              "<span class=\"led led-" + $st + "\"></span>" +
              "<div class=\"host-meta\">" +
                "<h3>" + (.host | @html) + "</h3>" +
                "<div class=\"mac-tag\">MAC " + (.mac | @html) + (if (.ip // "-") != "-" and (.ip // "") != "" then " · IP " + (.ip | @html) else "" end) + "</div>" +
              "</div>" +
            "</div>" +
            "<span class=\"badge badge-" + $st + "\">" + (etiqueta_est(.estado) | @html) + "</span>" +
          "</header>" +
          "<div class=\"stage-3d\">" +
            "<div class=\"iso-floor\"></div>" +
            "<div class=\"bars-3d\">" +
              prisma3d("CPU"; .cpu_pct; ((.cpu_pct | tostring) + "%")) +
              prisma3d("RAM"; .mem_pct; ((.mem_pct | tostring) + "%")) +
              prisma3d("DISCO"; .disco_pct; ((.disco_pct | tostring) + "%")) +
            "</div>" +
          "</div>" +
          "<div class=\"hist-wrap\">" +
            "<div class=\"hist-head\"><span>Historial CPU (20)</span><span class=\"spark-txt\">" + (.grafica_cpu | @html) + "</span></div>" +
            "<div class=\"hist-bars\">" + $hist_bars + "</div>" +
          "</div>" +
          "<div class=\"chips\">" +
            "<div class=\"chip\"><span>RAM</span><strong>" + (.mem_usada_mb | tostring | @html) + "/" + (.mem_total_mb | tostring | @html) + " MB</strong></div>" +
            "<div class=\"chip\"><span>Carga</span><strong>" + (.carga | @html) + "</strong></div>" +
            "<div class=\"chip\"><span>Top</span><strong>" + (.top_proc | @html) + "</strong></div>" +
            "<div class=\"chip\"><span>Uptime</span><strong>" + (fmt_uptime(.uptime_s) | @html) + " · " + (.edad_s | tostring | @html) + "s</strong></div>" +
          "</div>" +
        "</article>"
    end
  ' <<< "$resumen_json")"

  filas_html="$(jq -r \
    --argjson aviso "$UMBRAL_AVISO" \
    --argjson critico "$UMBRAL_CRITICO" '
    def clase_pct($p):
      if $p > $critico then "crit"
      elif $p >= $aviso then "warn"
      else "ok" end;

    def clase_est($e):
      if $e == "CAIDO" or $e == "CRITICO" then "badge-crit"
      elif $e == "AVISO" then "badge-warn"
      else "badge-ok" end;

    if length == 0 then
      "<tr><td colspan=\"10\" class=\"empty\">Esperando informes en el canal monitor...</td></tr>"
    else
      .[] |
      "<tr>" +
      "<td><strong>" + (.host | @html) + "</strong></td>" +
      "<td><code>" + (.mac | @html) + "</code>" + (if (.ip // "-") != "-" and (.ip // "") != "" then "<br><small style=\"color:#94a3b8\">" + (.ip | @html) + "</small>" else "" end) + "</td>" +
      "<td><span class=\"badge " + clase_est(.estado) + "\">" + (if .estado == "CAIDO" then "CAÍDO" elif .estado == "CRITICO" then "CRÍTICO" else .estado end | @html) + "</span></td>" +
      "<td class=\"" + clase_pct(.cpu_pct) + "\">" + (.cpu_pct | tostring | @html) + "%</td>" +
      "<td class=\"spark\">" + (.grafica_cpu | @html) + "</td>" +
      "<td class=\"" + clase_pct(.mem_pct) + "\">" + (.mem_pct | tostring | @html) + "% (" + (.mem_usada_mb | tostring | @html) + "/" + (.mem_total_mb | tostring | @html) + " MB)</td>" +
      "<td class=\"" + clase_pct(.disco_pct) + "\">" + (.disco_pct | tostring | @html) + "%</td>" +
      "<td><code>" + (.carga | @html) + "</code></td>" +
      "<td>" + (.top_proc | @html) + "</td>" +
      "<td>" + (.ts | @html) + " <small>(hace " + (.edad_s | tostring | @html) + "s)</small></td>" +
      "</tr>"
    end
  ' <<< "$resumen_json")"

  local tmp_html="${HTML_FILE}.tmp"
  cat <<EOF > "$tmp_html"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="${INTERVALO}">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Panel 3D de Monitorización — Grupo 7</title>
  <style>
    :root {
      --bg: #050816;
      --surface: rgba(15, 23, 42, 0.72);
      --border: rgba(148, 163, 184, 0.18);
      --text: #e2e8f0;
      --muted: #94a3b8;
      --cyan: #38bdf8;
      --ok: #22c55e;
      --ok-hi: #86efac;
      --ok-lo: #15803d;
      --warn: #eab308;
      --warn-hi: #fef08a;
      --warn-lo: #a16207;
      --crit: #ef4444;
      --crit-hi: #fca5a5;
      --crit-lo: #991b1b;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      font-family: "Inter", system-ui, -apple-system, "Segoe UI", sans-serif;
      color: var(--text);
      background:
        radial-gradient(ellipse 80% 50% at 50% -10%, rgba(56, 189, 248, 0.22), transparent 65%),
        radial-gradient(ellipse 60% 45% at 85% 95%, rgba(139, 92, 246, 0.16), transparent 60%),
        var(--bg);
      overflow-x: hidden;
    }

    /* Rejilla de horizonte 3D en perspectiva */
    .cyber-grid {
      position: fixed;
      inset: 0;
      z-index: -1;
      overflow: hidden;
      pointer-events: none;
    }
    .cyber-grid::before {
      content: "";
      position: absolute;
      left: -40%;
      right: -40%;
      bottom: -35%;
      height: 75vh;
      background-image:
        linear-gradient(to right, rgba(56, 189, 248, 0.14) 1px, transparent 1px),
        linear-gradient(to bottom, rgba(56, 189, 248, 0.14) 1px, transparent 1px);
      background-size: 48px 48px;
      transform: perspective(600px) rotateX(68deg);
      transform-origin: center bottom;
      mask-image: linear-gradient(to top, rgba(0,0,0,0.85), transparent 90%);
      -webkit-mask-image: linear-gradient(to top, rgba(0,0,0,0.85), transparent 90%);
      animation: gridFlow 12s linear infinite;
    }
    @keyframes gridFlow {
      from { background-position: 0 0; }
      to   { background-position: 0 48px; }
    }

    .container {
      max-width: 1360px;
      margin: 0 auto;
      padding: 28px 24px 48px;
    }

    /* Cabecera */
    .topbar {
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      align-items: center;
      gap: 16px;
      margin-bottom: 24px;
    }
    .title-block h1 {
      margin: 0;
      font-size: clamp(1.5rem, 2.5vw, 2.15rem);
      font-weight: 800;
      letter-spacing: -0.02em;
      background: linear-gradient(95deg, #f8fafc 0%, #38bdf8 55%, #a78bfa 100%);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
      text-shadow: 0 10px 30px rgba(56, 189, 248, 0.2);
    }
    .title-block .meta {
      margin-top: 6px;
      color: var(--muted);
      font-size: 0.88rem;
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
    }
    .live-pill {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 4px 11px;
      border-radius: 999px;
      background: rgba(34, 197, 94, 0.12);
      border: 1px solid rgba(34, 197, 94, 0.35);
      color: var(--ok-hi);
      font-size: 0.78rem;
      font-weight: 700;
      letter-spacing: 0.04em;
    }
    .live-pill::before {
      content: "";
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: var(--ok);
      box-shadow: 0 0 10px var(--ok);
      animation: pulse 1.6s ease-in-out infinite;
    }
    @keyframes pulse {
      0%, 100% { opacity: 1; transform: scale(1); }
      50%      { opacity: 0.45; transform: scale(0.8); }
    }

    /* Tarjetas KPI flotantes 3D */
    .kpi-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      gap: 16px;
      margin-bottom: 28px;
      perspective: 1100px;
    }
    .kpi {
      position: relative;
      padding: 16px 20px;
      border-radius: 16px;
      background: linear-gradient(155deg, rgba(30, 41, 59, 0.82), rgba(15, 23, 42, 0.62));
      border: 1px solid var(--border);
      border-top-color: rgba(255, 255, 255, 0.22);
      backdrop-filter: blur(14px);
      -webkit-backdrop-filter: blur(14px);
      box-shadow:
        0 18px 34px -16px rgba(0, 0, 0, 0.75),
        inset 0 1px 0 rgba(255, 255, 255, 0.08);
      transform: translateZ(0);
      transition: transform 0.28s ease, box-shadow 0.28s ease;
    }
    .kpi:hover {
      transform: translateY(-4px) rotateX(4deg);
      box-shadow: 0 24px 40px -14px rgba(56, 189, 248, 0.25);
    }
    .kpi-lbl { font-size: 0.76rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); }
    .kpi-val { margin-top: 6px; font-size: 1.9rem; font-weight: 800; letter-spacing: -0.02em; }
    .kpi-sub { margin-top: 2px; font-size: 0.78rem; color: var(--muted); }

    /* Grid de tarjetas de servidor 3D */
    .cards-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(330px, 1fr));
      gap: 24px;
      margin-bottom: 34px;
      perspective: 1200px;
    }
    .server-card {
      position: relative;
      border-radius: 22px;
      padding: 20px 22px 22px;
      background: linear-gradient(160deg, rgba(30, 41, 59, 0.84) 0%, rgba(11, 18, 36, 0.86) 100%);
      border: 1px solid var(--border);
      border-top-color: rgba(255, 255, 255, 0.22);
      backdrop-filter: blur(16px);
      -webkit-backdrop-filter: blur(16px);
      box-shadow:
        0 26px 50px -20px rgba(0, 0, 0, 0.85),
        0 0 0 1px rgba(255, 255, 255, 0.04) inset;
      transform-style: preserve-3d;
      transition: transform 0.22s ease, box-shadow 0.25s ease, border-color 0.25s ease;
      overflow: hidden;
    }
    .server-card.card-ok   { box-shadow: 0 24px 48px -22px rgba(34, 197, 94, 0.35), 0 26px 50px -20px rgba(0,0,0,0.85); }
    .server-card.card-warn { border-color: rgba(234, 179, 8, 0.42); box-shadow: 0 24px 48px -22px rgba(234, 179, 8, 0.42), 0 26px 50px -20px rgba(0,0,0,0.85); }
    .server-card.card-crit { border-color: rgba(239, 68, 68, 0.58); box-shadow: 0 24px 52px -18px rgba(239, 68, 68, 0.55), 0 26px 50px -20px rgba(0,0,0,0.9); animation: alertGlow 2s ease-in-out infinite; }
    @keyframes alertGlow {
      0%, 100% { border-color: rgba(239, 68, 68, 0.55); }
      50%      { border-color: rgba(248, 113, 113, 0.95); }
    }
    .card-glare {
      position: absolute;
      inset: 0;
      pointer-events: none;
      background: radial-gradient(circle at var(--mx, 50%) var(--my, 20%), rgba(255,255,255,0.11), transparent 55%);
      opacity: 0.7;
    }

    .card-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 14px;
      transform: translateZ(18px);
    }
    .host-id { display: flex; align-items: center; gap: 10px; }
    .host-meta { display: flex; flex-direction: column; gap: 2px; }
    .host-id h3 { margin: 0; font-size: 1.15rem; font-weight: 700; letter-spacing: 0.01em; }
    .mac-tag { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.72rem; color: var(--cyan); opacity: 0.9; }
    .led { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
    .led-ok   { background: var(--ok);   box-shadow: 0 0 12px var(--ok); }
    .led-warn { background: var(--warn); box-shadow: 0 0 12px var(--warn); }
    .led-crit { background: var(--crit); box-shadow: 0 0 14px var(--crit); animation: pulse 1s infinite; }

    /* Escenario isométrico 3D con prismas reales */
    .stage-3d {
      position: relative;
      height: 176px;
      margin: 8px 0 16px;
      display: flex;
      align-items: flex-end;
      justify-content: center;
      perspective: 720px;
      transform-style: preserve-3d;
    }
    .iso-floor {
      position: absolute;
      bottom: 24px;
      width: 86%;
      height: 70px;
      border-radius: 14px;
      background:
        linear-gradient(90deg, rgba(56,189,248,0.12) 1px, transparent 1px),
        linear-gradient(rgba(56,189,248,0.12) 1px, transparent 1px),
        linear-gradient(135deg, rgba(30, 41, 59, 0.7), rgba(15, 23, 42, 0.9));
      background-size: 18px 18px, 18px 18px, 100% 100%;
      border: 1px solid rgba(56, 189, 248, 0.28);
      box-shadow: 0 18px 28px rgba(0, 0, 0, 0.65), inset 0 0 24px rgba(56, 189, 248, 0.12);
      transform: rotateX(62deg) rotateZ(-8deg);
    }
    .bars-3d {
      position: relative;
      z-index: 2;
      display: flex;
      gap: 34px;
      align-items: flex-end;
      padding-bottom: 10px;
      transform-style: preserve-3d;
    }
    .bar-col {
      display: flex;
      flex-direction: column;
      align-items: center;
      width: 58px;
    }
    .bar-val {
      font-size: 0.85rem;
      font-weight: 800;
      margin-bottom: 8px;
      text-shadow: 0 2px 10px rgba(0, 0, 0, 0.8);
    }
    .bar-well {
      width: 34px;
      height: 108px;
      display: flex;
      align-items: flex-end;
      justify-content: center;
      perspective: 500px;
    }
    .prism {
      position: relative;
      width: 32px;
      height: var(--h, 20%);
      min-height: 8px;
      transform-style: preserve-3d;
      transform: rotateX(-14deg) rotateY(-28deg);
      transition: height 0.55s cubic-bezier(0.22, 1, 0.36, 1), transform 0.3s ease;
    }
    .server-card:hover .prism {
      transform: rotateX(-10deg) rotateY(-36deg) translateY(-2px);
    }
    .prism .face {
      position: absolute;
      backface-visibility: visible;
    }
    .prism .front {
      inset: 0;
      transform: translateZ(16px);
      border-radius: 2px 2px 3px 3px;
    }
    .prism .side {
      top: 0;
      bottom: 0;
      left: 0;
      width: 32px;
      transform: rotateY(90deg) translateZ(16px);
      border-radius: 2px;
    }
    .prism .top {
      top: 0;
      left: 0;
      width: 32px;
      height: 32px;
      transform: rotateX(90deg) translateZ(16px);
      border-radius: 3px;
    }
    .prism-ok .front   { background: linear-gradient(180deg, #4ade80, #16a34a); box-shadow: 0 0 18px rgba(34, 197, 94, 0.45); }
    .prism-ok .side    { background: linear-gradient(180deg, #16a34a, #14532d); }
    .prism-ok .top     { background: #bbf7d0; box-shadow: 0 0 16px rgba(134, 239, 172, 0.8); }

    .prism-warn .front { background: linear-gradient(180deg, #fde047, #ca8a04); box-shadow: 0 0 18px rgba(234, 179, 8, 0.5); }
    .prism-warn .side  { background: linear-gradient(180deg, #ca8a04, #713f12); }
    .prism-warn .top   { background: #fef9c3; box-shadow: 0 0 16px rgba(254, 240, 138, 0.85); }

    .prism-crit .front { background: linear-gradient(180deg, #f87171, #dc2626); box-shadow: 0 0 22px rgba(239, 68, 68, 0.65); }
    .prism-crit .side  { background: linear-gradient(180deg, #b91c1c, #450a0a); }
    .prism-crit .top   { background: #fecaca; box-shadow: 0 0 18px rgba(252, 165, 165, 0.9); }

    .bar-lbl {
      margin-top: 12px;
      font-size: 0.72rem;
      font-weight: 700;
      letter-spacing: 0.08em;
      color: var(--muted);
    }

    /* Mini-histograma 3D CPU */
    .hist-wrap {
      background: rgba(5, 8, 22, 0.52);
      border: 1px solid rgba(148, 163, 184, 0.14);
      border-radius: 12px;
      padding: 10px 12px;
      margin-bottom: 14px;
    }
    .hist-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      font-size: 0.74rem;
      color: var(--muted);
      margin-bottom: 8px;
    }
    .spark-txt { font-family: monospace; font-size: 0.95rem; color: var(--cyan); letter-spacing: 1px; }
    .hist-bars {
      height: 36px;
      display: flex;
      align-items: flex-end;
      gap: 4px;
    }
    .h-bar {
      flex: 1;
      min-width: 6px;
      border-radius: 3px 3px 1px 1px;
      box-shadow: inset 0 1px 0 rgba(255,255,255,0.45);
    }
    .h-ok   { background: linear-gradient(180deg, #4ade80, #15803d); }
    .h-warn { background: linear-gradient(180deg, #fde047, #a16207); }
    .h-crit { background: linear-gradient(180deg, #f87171, #991b1b); }

    /* Chips de telemetría */
    .chips {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 8px;
    }
    .chip {
      background: rgba(15, 23, 42, 0.65);
      border: 1px solid rgba(148, 163, 184, 0.12);
      border-radius: 10px;
      padding: 7px 10px;
      font-size: 0.76rem;
      display: flex;
      flex-direction: column;
      gap: 2px;
      overflow: hidden;
    }
    .chip span { color: var(--muted); font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.06em; }
    .chip strong { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: #f1f5f9; }

    /* Tabla detallada */
    .table-wrap {
      border-radius: 18px;
      overflow-x: auto;
      background: var(--surface);
      border: 1px solid var(--border);
      backdrop-filter: blur(14px);
      -webkit-backdrop-filter: blur(14px);
      box-shadow: 0 22px 46px -18px rgba(0, 0, 0, 0.8);
    }
    .section-title {
      margin: 0 0 12px;
      font-size: 0.92rem;
      text-transform: uppercase;
      letter-spacing: 0.1em;
      color: var(--cyan);
    }
    table { width: 100%; border-collapse: collapse; min-width: 780px; }
    th, td { padding: 13px 15px; text-align: left; border-bottom: 1px solid rgba(148, 163, 184, 0.12); font-size: 0.88rem; }
    th { background: rgba(5, 8, 22, 0.68); color: var(--muted); font-size: 0.74rem; text-transform: uppercase; letter-spacing: 0.07em; }
    tbody tr:hover { background: rgba(56, 189, 248, 0.06); }
    .ok { color: #4ade80; font-weight: 700; }
    .warn { color: #facc15; font-weight: 700; }
    .crit { color: #f87171; font-weight: 800; }
    .spark { font-family: monospace; font-size: 1.1rem; letter-spacing: 1px; color: var(--cyan); }
    .badge { padding: 4px 10px; border-radius: 999px; font-size: 0.74rem; font-weight: 800; letter-spacing: 0.04em; }
    .badge-ok { background: rgba(22, 163, 74, 0.22); color: #86efac; border: 1px solid rgba(74, 222, 128, 0.35); }
    .badge-warn { background: rgba(202, 138, 4, 0.24); color: #fde047; border: 1px solid rgba(250, 204, 21, 0.4); }
    .badge-crit { background: rgba(220, 38, 38, 0.26); color: #fca5a5; border: 1px solid rgba(248, 113, 113, 0.45); }
    .empty, .empty-3d { text-align: center; color: var(--muted); padding: 38px 20px; border-radius: 18px; background: var(--surface); border: 1px dashed var(--border); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.82rem; color: #cbd5e1; }
  </style>
</head>
<body>
  <div class="cyber-grid"></div>
  <main class="container">
    <header class="topbar">
      <div class="title-block">
        <h1>Panel 3D de Monitorización — Grupo 7</h1>
        <div class="meta">
          <span class="live-pill">LIVE · ${INTERVALO}s</span>
          <span>Canal: <strong>${CANAL}</strong></span>
          <span>Actualizado: <strong>${hora_actual} UTC</strong></span>
          <span>Umbrales: OK &lt; ${UMBRAL_AVISO}% · AVISO ${UMBRAL_AVISO}–${UMBRAL_CRITICO}% · CRÍTICO &gt; ${UMBRAL_CRITICO}% · CAÍDO &gt; ${UMBRAL_CAIDO_S}s</span>
        </div>
      </div>
    </header>

    <section class="kpi-grid">
      <div class="kpi">
        <div class="kpi-lbl">Equipos monitorizados</div>
        <div class="kpi-val" style="color:#38bdf8">${kpi_total}</div>
        <div class="kpi-sub">Canal ${CANAL}</div>
      </div>
      <div class="kpi">
        <div class="kpi-lbl">Estado OK</div>
        <div class="kpi-val ok">${kpi_ok}</div>
        <div class="kpi-sub">Dentro de umbrales</div>
      </div>
      <div class="kpi">
        <div class="kpi-lbl">En alerta / Caídos</div>
        <div class="kpi-val $( (( kpi_alerta > 0 )) && echo crit || echo ok )">${kpi_alerta}</div>
        <div class="kpi-sub">Aviso, crítico o &gt;${UMBRAL_CAIDO_S}s</div>
      </div>
      <div class="kpi">
        <div class="kpi-lbl">CPU media del aula</div>
        <div class="kpi-val" style="color:#c084fc">${kpi_cpu_media}%</div>
        <div class="kpi-sub">Último muestreo</div>
      </div>
    </section>

    <h2 class="section-title">Vista isométrica 3D en tiempo real</h2>
    <section class="cards-grid">
      ${cards_html}
    </section>

    <h2 class="section-title">Detalle tabular de telemetría</h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Host</th>
            <th>MAC / IP</th>
            <th>Estado</th>
            <th>CPU</th>
            <th>Historial CPU (20)</th>
            <th>Memoria</th>
            <th>Disco /</th>
            <th>Carga (1/5/15)</th>
            <th>Top proceso</th>
            <th>Último informe</th>
          </tr>
        </thead>
        <tbody>
          ${filas_html}
        </tbody>
      </table>
    </div>
  </main>

  <script>
    document.querySelectorAll('[data-tilt]').forEach(function (card) {
      card.addEventListener('mousemove', function (e) {
        var r = card.getBoundingClientRect();
        var x = (e.clientX - r.left) / r.width;
        var y = (e.clientY - r.top) / r.height;
        var rx = (0.5 - y) * 10;
        var ry = (x - 0.5) * 12;
        card.style.transform = 'perspective(900px) rotateX(' + rx.toFixed(2) + 'deg) rotateY(' + ry.toFixed(2) + 'deg) translateY(-4px)';
        card.style.setProperty('--mx', (x * 100).toFixed(1) + '%');
        card.style.setProperty('--my', (y * 100).toFixed(1) + '%');
      });
      card.addEventListener('mouseleave', function () {
        card.style.transform = '';
      });
    });
  </script>
</body>
</html>
EOF
  mv "$tmp_html" "$HTML_FILE"
}

actualizar_panel() {
  cargar_umbrales

  local raw_json ahora_epoch hora_actual ts_now resumen_json
  ahora_epoch="$(date -u +%s)"
  hora_actual="$(date -u +"%H:%M:%S")"
  ts_now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [[ -n "$DESDE_ARCHIVO" ]]; then
    raw_json="$(cat "$DESDE_ARCHIVO")"
  else
    if ! raw_json="$(curl -sS --compressed --max-time 30 "$SYNC_URL")"; then
      echo "[ERROR] No se pudo consultar $SYNC_URL" >&2
      return 1
    fi
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "$raw_json"; then
    echo "[ERROR] La respuesta de $SYNC_URL no es JSON válido." >&2
    return 1
  fi

  resumen_json="$(obtener_resumen_hosts_json "$raw_json" "$ahora_epoch")"
  dibujar_panel_terminal "$resumen_json" "$hora_actual"
  evaluar_y_enviar_alertas "$resumen_json" "$ts_now"

  if [[ "$MODO_HTML" == true ]]; then
    generar_panel_html "$resumen_json" "$hora_actual"
  fi
}

limpiar_al_salir() {
  if [[ -n "${SLEEP_PID:-}" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
  fi
  echo ""
  echo "[INFO] Panel detenido."
  exit 0
}

parsear_argumentos() {
  while (( $# > 0 )); do
    case "$1" in
      -i|--intervalo)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        INTERVALO="$2"
        shift 2
        ;;
      -s|--sync)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        SYNC_URL="$2"
        shift 2
        ;;
      -w|--webhook)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        WEBHOOK_URL="$2"
        shift 2
        ;;
      -u|--umbrales)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        UMBRALES_FILE="$2"
        shift 2
        ;;
      --expirar)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        EXPIRAR_CLI="$2"
        shift 2
        ;;
      --html)
        MODO_HTML=true
        if [[ $# -ge 2 && "$2" != -* ]]; then
          HTML_FILE="$2"
          shift 2
        else
          shift
        fi
        ;;
      --servir)
        MODO_HTML=true
        SERVIR_HTTP=true
        if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
          PUERTO_HTTP="$2"
          shift 2
        else
          shift
        fi
        ;;
      --sin-alertas)
        ENVIAR_ALERTAS=false
        shift
        ;;
      -1|--once)
        SOLO_UNA_VEZ=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --desde-archivo)
        [[ $# -lt 2 ]] && { echo "[ERROR] Falta valor para $1" >&2; exit 1; }
        DESDE_ARCHIVO="$2"
        shift 2
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
    actualizar_panel
    exit 0
  fi

  trap limpiar_al_salir INT TERM

  if [[ "$SERVIR_HTTP" == true ]]; then
    local dir_html
    dir_html="$(dirname "$HTML_FILE")"
    python3 -m http.server "$PUERTO_HTTP" --directory "$dir_html" >/dev/null 2>&1 &
    HTTP_PID=$!
    echo "[INFO] Servidor web iniciado en http://0.0.0.0:${PUERTO_HTTP}/ (PID $HTTP_PID)"
  fi

  SLEEP_PID=""
  while true; do
    actualizar_panel || true
    sleep "$INTERVALO" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" || true
    SLEEP_PID=""
  done
}

main "$@"
