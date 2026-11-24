# Registro de prompts y correcciones (`prompts.md`)

**Grupo:** Grupo 7  
**Ejercicio:** Ejercicio 2 — Monitorización de recursos con panel (`agente.sh` y `panel.sh`)

---

## Prompt 1 — Cálculo de porcentaje de CPU desde `/proc/stat` y ritmo del agente

**Prompt usado:**
> ¿Cómo calculo el porcentaje de CPU a partir de dos lecturas de `/proc/stat` separadas 1 segundo? Explícame cada columna y asegúrate de que el resultado sea numérico para pasarlo con `--argjson` a `jq`.

**Qué generó inicialmente y qué se corrigió:**
1. **Separador decimal con coma en locales en español (`es_ES.UTF-8`):** `awk` formateaba `12,5` en lugar de `12.5`, provocando errores de parseo en `jq --argjson`.
   - *Corrección:* Exportar `LC_ALL=C` al inicio de `agente.sh` y `panel.sh`.
2. **Cálculo de tiempo inactivo incompleto:** La primera versión solo usaba la 4.ª columna (`idle`) y omitía `iowait` (5.ª columna) y `steal` (8.ª columna, relevante en máquinas virtuales).
   - *Corrección:* Sumar `idle + iowait` para el tiempo inactivo y las 8 columnas (`user..steal`) para el total, protegiendo además el caso `dt <= 0` para evitar división por cero y acotando el porcentaje entre `0` y `100`.
3. **Deriva del intervalo del bucle principal:** Al hacer `sleep 1` dentro de `calcular_cpu_pct` y luego `sleep "$INTERVALO"`, cada ciclo duraba `INTERVALO + 1` segundos.
   - *Corrección:* Calcular `espera=$(( INTERVALO > 1 ? INTERVALO - 1 : 0 ))` para respetar el intervalo configurado por el usuario.

---

## Prompt 2 — Convertir `ps` y `df` a JSON únicamente con `jq`

**Prompt usado:**
> Convierte la salida de `ps -eo pid,comm,%cpu --sort=-%cpu` (top 3) y de `df -P` en arrays JSON usando solo `jq`, sin bucles de Bash, y respetando que `pid`, `cpu` y `pct` sean números.

**Qué generó inicialmente y qué se corrigió:**
1. **Procesos cuyo nombre (`comm`) contiene espacios:** Usar `split(" ")` rompía líneas como `1234 Web Content 5.1`.
   - *Corrección:* Usar `capture("^\\s*(?<pid>[0-9]+)\\s+(?<cmd>.+?)\\s+(?<cpu>[0-9]+(?:\\.[0-9]+)?)\\s*$")` en `jq`, que captura nombres con espacios y acepta tanto porcentajes con decimales (`5.1`) como enteros (`100`).
2. **Números serializados como cadenas:** Al pasar variables con `--arg` en `jq`, `cpu_pct` y `uptime_s` quedaban entrecomillados (`"12.5"`).
   - *Corrección:* Pasar todas las métricas numéricas y objetos/arrays con `--argjson` y validar tipos con `jq -e '.host and (.cpu_pct | type == "number") and (.mem.pct | type == "number")'`.
3. **Ruido de montajes virtuales en `df -P`:** El JSON incluía entradas `tmpfs`, `devtmpfs`, `squashfs` y `efivarfs` que no representan discos reales.
   - *Corrección:* Ejecutar `df -P -l -x tmpfs -x devtmpfs -x squashfs -x efivarfs` (con fallback a `df -P /`), deduplicar por `.montaje` y ordenar dejando `/` en primer lugar.
4. **Respuesta del webhook con `ok: false` bajo HTTP `200`:** Comprobar solo el código de salida de `curl` no detectaba rechazos lógicos del servidor.
   - *Corrección:* Capturar `%{http_code}`, añadir cabecera `X-Canal`, verificar el rango `2xx` y comprobar con `jq -e` que no venga `"ok": false`, registrando cualquier fallo en `agente.log` sin abortar el bucle (`recolectar_y_enviar || true`).

---

## Prompt 3 — Panel en tiempo real (`panel.sh`) y compatibilidad con `/sync`

**Prompt usado:**
> Crea `panel.sh` que consulte el endpoint `/sync` cada 5 segundos, agrupe los informes por host con `jq` quedándose con el último, pinte colores por umbrales (<60 verde, 60-85 amarillo, >85 rojo) y marque como `CAÍDO` si supera 30 segundos sin reportar.

**Qué generó inicialmente y qué se corrigió:**
1. **Formato del servidor `/sync` vs `.datos.host`:** El enunciado mostraba `group_by(.datos.host)`, pero el servidor real (`/sync`) devuelve los campos a nivel raíz dentro de `.messages[]` (`{"canal": "monitor", "host": "...", ...}`).
   - *Corrección:* Normalizar en `jq` ambos formatos (`if has("datos") and (.datos | type == "object") then .datos else . end`), de modo que funciona con `/sync` real y también si otro grupo envía envuelto en `.datos`.
2. **Desfase horario entre relojes de distintas VMs:** Comparar `now` con `ts` del cliente podía dar edades negativas si el reloj de otra VM iba unos segundos adelantado.
   - *Corrección:* Priorizar `_recibido` (sellado por el propio servidor) con fallback a `ts`, normalizando milisegundos con `sub("\\.[0-9]+Z$"; "Z")` antes de `fromdateiso8601`, y acotando edades negativas a `0`.
3. **`tput` en salidas no interactivas:** `tput clear` fallaba con `set -euo pipefail` cuando se redirigía la salida o en pruebas sin TTY.
   - *Corrección:* Comprobar `[[ -t 1 ]]` antes de limpiar pantalla con `tput`/`clear`.

---

## Prompt 4 — Ampliaciones de Fase 2 (HTML `@html`, alertas sin spam, sparkline y `umbrales.json`)

**Prompt usado:**
> Añade al panel: generación de `index.html` con heredoc y `jq -r` usando `@html`, publicación de alertas al canal `alertas` solo cuando cambie de estado, mini-gráfica de CPU con `▁▂▃▄▅▆▇█` y umbrales leídos de `umbrales.json`.

**Qué generó inicialmente y qué se corrigió:**
1. **Envío duplicado de alertas en cada refresco de 5s:** La primera propuesta enviaba la alerta cada vez que `cpu_pct > 85`.
   - *Corrección:* Guardar el último estado de cada host en `.estado_panel.json` y publicar al canal `alertas` únicamente cuando `estado_actual != estado_anterior`.
2. **Lectura parcial de `index.html` mientras se regenera:** Escribir directamente sobre `index.html` podía dejar la página a medias si el navegador recargaba justo en ese instante.
   - *Corrección:* Generar `index.html.tmp` y reemplazar atómicamente con `mv`.
3. **Limpieza del servidor HTTP embebido (`--servir`):** Al pulsar `Ctrl+C`, `python3 -m http.server` podía quedar colgado en segundo plano.
   - *Corrección:* Guardar `$HTTP_PID`, pasarlo a `limpiar_al_salir` mediante `trap limpiar_al_salir INT TERM` y validar que `python3` esté instalado cuando se activa `--servir`.

---

## Prompt 5 — Rediseño del panel web a interfaz 3D isométrica

**Prompt usado:**
> Mejora `generar_panel_html` en `panel.sh` para generar un panel web más visual en estilo 3D isométrico (tarjetas KPI, prismas 3D en CSS puro para CPU/RAM/DISCO, mini-histograma de CPU, efecto tilt al mover el ratón y tabla detallada debajo) sin depender de librerías externas ni romper el escape `@html` ni `shellcheck`.

**Qué generó inicialmente y qué se corrigió:**
1. **Barras 3D invisibles cuando el uso es cercano al `0%`:** Con porcentajes muy bajos (p. ej. `0.5%` de CPU), la altura del prisma CSS colapsaba y las caras superior/lateral se solapaban.
   - *Corrección:* Añadir en `jq` la función `clamp($v)` que fija un mínimo visual del `4%` y un máximo del `100%` manteniendo en la etiqueta el porcentaje real exacto.
2. **Escapado seguro y compatibilidad con heredoc de Bash:** Al mezclar variables de CSS/JS con `cat <<EOF`, había riesgo de expansión involuntaria de `$` en Bash o inyección HTML en nombres de host/procesos.
   - *Corrección:* Pasar todos los campos dinámicos (`host`, `estado`, `grafica_cpu`, `carga`, `top_proc`, valores numéricos) por `@html` en `jq`, evitar `$` de Bash dentro del bloque `<script>` y validar el script completo con `shellcheck panel.sh` sin avisos.
3. **Cálculo de CPU media con 0 hosts:** Al arrancar antes de recibir el primer mensaje de `/sync`, `add / length` producía división por cero en `jq`.
   - *Corrección:* Proteger explícitamente el cálculo de `kpi_cpu_media` con `if length == 0 then "0.0" else ... end` y mostrar un estado vacío informativo en la cuadrícula 3D y en la tabla.
4. **Alineación Unicode en terminal y cierre inmediato en pruebas en vivo:** Al probar el panel con `LC_ALL=C` y 3 equipos en paralelo se detectaron dos detalles:
   - *Desalineación de columnas con caracteres UTF-8:* `printf '%-20s'` y `printf '%-9s'` cuentan bytes en `LC_ALL=C`, desplazando la tabla cuando había tildes (`CAÍDO`, `CRÍTICO`) o mini-gráficas cortas (`▁` ocupa 3 bytes). Se rellenó el ancho visual exacto de la mini-gráfica en `jq` (`length` en caracteres Unicode) y de las etiquetas de estado en `panel.sh`.
   - *Respuesta inmediata a `SIGTERM` durante `sleep`:* Se sustituyó `sleep` bloqueante por `sleep ... & SLEEP_PID=$!; wait "$SLEEP_PID"` en `agente.sh` y `panel.sh` para terminar al instante tanto el bucle como `python3 -m http.server`.

---

## Prompt 6 — Identificación persistente por dirección MAC (IPs dinámicas)

**Prompt usado:**
> Haz que `agente.sh` y `panel.sh` identifiquen los dispositivos por su dirección MAC (autodetectada) y muestren la MAC e IP actual en el panel 3D y la tabla, sin romper compatibilidad con mensajes antiguos ni duplicar el propio equipo al actualizar el agente.

**Qué generó inicialmente y qué se corrigió:**
1. **Duplicación del mismo host entre informes antiguos sin `mac` y nuevos con `mac`:** Si `panel.sh` agrupaba directamente por `.datos.mac // .datos.host`, los mensajes anteriores de `kali-g7` quedaban en una tarjeta `CAÍDO` aparte de la nueva tarjeta con MAC.
   - *Corrección:* Construir en `jq` un mapa `$host2mac` con los mensajes que ya reportan MAC y asignar esa misma MAC a los mensajes previos del mismo host, fusionando todo el historial de CPU en un único dispositivo.
2. **Limpieza opcional de pruebas antiguas (`CAÍDO`):** Se añadió `expirar_s` en `umbrales.json` y `--expirar SEG` en `panel.sh` (por defecto `0` para mantener visibles los equipos caídos según el enunciado, pero configurable cuando se desean ocultar pruebas viejas).
