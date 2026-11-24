# Ejercicio 2: Monitorización de recursos con panel (`agente.sh` y `panel.sh`)

**Grupo:** Grupo 7  
**Canal principal:** `monitor` · **Canal de alertas:** `alertas`

---

## 1. Estructura del proyecto

```text
monitor-recursos/
├── agente.sh           # Agente ligero que recoge métricas y las envía al canal "monitor"
├── panel.sh            # Panel en terminal + generador de panel web 3D + emisor de alertas
├── umbrales.json       # Umbrales configurables (aviso, crítico, caída e historial)
├── index.html          # Panel web 3D generado automáticamente con --html
├── README.md           # Documentación de uso, contratos JSON y guion de demo
└── prompts.md          # Registro de prompts usados con Claude y correcciones aplicadas
```

> Durante la ejecución se generan también `.estado_panel.json` (estado previo por host para evitar spam de alertas) y `agente.log` (registro de errores de envío del agente).

---

## 2. Requisitos previos

Herramientas necesarias en Kali Linux: `bash`, `curl`, `jq`, `shellcheck`, `awk`, `ps`, `df` (y `python3` si se usa `--servir` para el panel web).

```bash
sudo apt update && sudo apt install -y jq shellcheck curl
chmod +x agente.sh panel.sh
shellcheck agente.sh panel.sh
```

---

## 3. Configuración de endpoints

Los endpoints se cargan automáticamente desde `.env` (copia `.env.example` a `.env`), mediante variables de entorno (`WEBHOOK_URL`, `SYNC_URL`) o con `-w` / `-s`:

- **Enviar (POST con JSON):** `WEBHOOK_URL` (ejemplo: `http://SERVIDOR_AULA:9007/webhook/TU_TOKEN` → responde `{ "ok": true, ... }`)
- **Recuperar (GET):** `SYNC_URL` (ejemplo: `http://SERVIDOR_AULA:8087/sync`)

Ambos scripts envían la cabecera `X-Canal` junto al campo `"canal"` en el JSON y validan tanto el código HTTP `2xx` como la respuesta del servidor.

---

## 4. Instrucciones de ejecución

### 4.1 Agente (`agente.sh`)

Recoge cada `N` segundos (por defecto `10`, compensando el segundo de muestreo de CPU) y construye el JSON con tipos numéricos reales usando `jq --argjson`:
- **CPU:** dos lecturas de `/proc/stat` separadas 1 segundo (`idle + iowait` frente a las 8 columnas `user..steal`).
- **Memoria:** `MemTotal` y `MemAvailable` desde `/proc/meminfo`.
- **Disco:** `df -P -l` excluyendo sistemas de archivos virtuales (`tmpfs`, `devtmpfs`, `squashfs`, `efivarfs`).
- **Carga:** `/proc/loadavg` (`[1m, 5m, 15m]`).
- **Uptime:** `/proc/uptime` en segundos enteros.
- **Top 3 procesos por CPU:** `ps -eo pid,comm,%cpu --sort=-%cpu --no-headers` convertido directamente a JSON con `jq`, sin bucles de Bash.

Los errores de conexión o rechazo del webhook se registran con marca temporal UTC en `agente.log` sin detener el bucle.

#### Opciones de `agente.sh`

| Opción | Descripción | Valor por defecto |
| --- | --- | --- |
| `-i, --intervalo SEGUNDOS` | Intervalo entre envíos (entero `>= 1`). | `10` |
| `-H, --host NOMBRE` | Nombre del equipo en el campo `"host"`. | `kali-g7` |
| `-m, --mac DIRECCION_MAC` | Dirección MAC identificadora del equipo (autodetectada si se omite). | Autodetectada |
| `-w, --webhook URL` | URL destino de peticiones `POST`. | Endpoint Grupo 7 |
| `-c, --canal NOMBRE` | Canal de publicación. | `monitor` |
| `-l, --log FICHERO` | Fichero donde registrar errores de envío. | `./agente.log` |
| `-1, --once` | Recoger y enviar un único informe y salir. | Desactivado |
| `--dry-run` | Mostrar el JSON generado sin enviarlo por HTTP. | Desactivado |
| `-h, --help` | Mostrar la ayuda del script. | — |

**Variables de entorno soportadas:** `WEBHOOK_URL`, `HOST_NOMBRE`, `HOST_MAC`, `CANAL`, `LOG_FILE`.

```bash
# Ejecutar agente con intervalo por defecto (10s) y host kali-g7
./agente.sh

# Personalizar intervalo (5s) y nombre de equipo (útil si corren varios equipos)
./agente.sh -i 5 -H kali-g7-pc1

# Envío único en modo prueba (sin POST) para inspeccionar el JSON
./agente.sh --once --dry-run
```

---

### 4.2 Panel (`panel.sh`)

Consulta `GET /sync` cada `5` segundos, normaliza tanto mensajes planos (`.messages[]`) como envueltos en `.datos`, agrupa por host quedándose con el último informe y calcula el estado según [umbrales.json](./umbrales.json):
- **Verde (`OK`):** `< 60%`
- **Amarillo (`AVISO`):** `60% – 85%`
- **Rojo (`CRÍTICO`):** `> 85%`
- **Rojo destacado (`CAÍDO`):** sin informes desde hace más de `30` segundos.

#### Opciones de `panel.sh`

| Opción | Descripción | Valor por defecto |
| --- | --- | --- |
| `-i, --intervalo SEGUNDOS` | Intervalo de refresco (terminal y `<meta refresh>`). | `5` |
| `-s, --sync URL` | URL `GET` de consulta de mensajes. | Endpoint `/sync` |
| `-w, --webhook URL` | URL `POST` para publicar alertas. | Endpoint Grupo 7 |
| `-u, --umbrales FICHERO` | Fichero JSON de umbrales (se recarga en cada ciclo). | `./umbrales.json` |
| `--expirar SEGUNDOS` | Oculta equipos inactivos tras `N` segundos (`0` = no ocultar nunca). | `0` (o `expirar_s`) |
| `--html [FICHERO]` | Genera el panel web 3D en HTML con autorrecarga. | `./index.html` |
| `--servir [PUERTO]` | Activa `--html` y levanta `python3 -m http.server` en segundo plano (se detiene con `trap` al salir). | `8080` |
| `--sin-alertas` | Desactiva la publicación en el canal `alertas`. | Alertas activas |
| `-1, --once` | Ejecutar una única actualización y salir. | Desactivado |
| `--dry-run` | Simula el envío de alertas mostrándolas por pantalla. | Desactivado |
| `--desde-archivo FILE` | Lee una respuesta `/sync` desde un JSON local (pruebas offline). | — |
| `-h, --help` | Mostrar la ayuda del script. | — |

**Variables de entorno soportadas:** `SYNC_URL`, `WEBHOOK_URL`, `CANAL`, `CANAL_ALERTAS`, `UMBRALES_FILE`, `HTML_FILE`, `ESTADO_FILE`.

```bash
# Panel en terminal en tiempo real (refresco cada 5s)
./panel.sh

# Panel en terminal + generación de index.html 3D con autorrecarga cada 5s
./panel.sh --html

# Panel en terminal + generar index.html 3D y servirlo en http://localhost:8080/
./panel.sh --html --servir 8080

# Prueba puntual con datos guardados localmente sin enviar alertas reales
./panel.sh --once --dry-run --html --desde-archivo muestra_sync.json
```

---

## 5. Ampliaciones implementadas (Fase 2)

1. **Panel web 3D isométrico (`--html` y `--servir`):** Genera `index.html` de forma atómica (`index.html.tmp` → `mv`) usando heredoc de Bash y `jq -r` con `@html` para escapar cadenas de forma segura. Incluye:
   - Autorrecarga automática sincronizada con `-i` (`<meta http-equiv="refresh" content="5">`).
   - Tarjetas KPI resumen (equipos monitorizados, OK, en alerta/caídos y CPU media del aula).
   - Tarjetas por servidor con **prismas 3D en CSS** (CPU, RAM y DISCO), efecto interactivo *tilt* al pasar el ratón, chips de telemetría (RAM, carga, top proceso, uptime) y mini-histograma de CPU.
   - Tabla completa de telemetría detallada debajo de la vista 3D.
2. **Alertas en canal `alertas` sin spam:** Persiste el último estado de cada host en `.estado_panel.json` y publica un evento JSON en `"canal": "alertas"` únicamente cuando cambia de estado (`OK` / `AVISO` / `CRITICO` / `CAIDO`).
3. **Mini-gráfica de CPU (`▁▂▃▄▅▆▇█`):** Muestra la evolución de los últimos 20 informes de cada equipo tanto en terminal como en `index.html`.
4. **Umbrales configurables en caliente (`umbrales.json`):** Permite ajustar `aviso`, `critico`, `caido_s`, `expirar_s` e `historial_grafica` sin reiniciar el panel.
5. **Identificación persistente por MAC (`mac` e `ip`):** `agente.sh` autodetecta la MAC de la interfaz principal y su IP actual; `panel.sh` agrupa los dispositivos por MAC (enlazando informes históricos previos del mismo host), de modo que un equipo con IP dinámica por DHCP sigue identificándose como el mismo dispositivo y muestra su MAC e IP actual en las tarjetas 3D y en la tabla.

---

## 6. Configuración y ejemplos de JSON

### 6.1 Umbrales (`umbrales.json`)
```json
{
  "descripcion": "Umbrales de monitorización de recursos - Grupo 7",
  "aviso": 60,
  "critico": 85,
  "caido_s": 30,
  "expirar_s": 0,
  "historial_grafica": 20
}
```

### 6.2 Informe de métricas (`canal: "monitor"`)
```json
{
  "canal": "monitor",
  "host": "kali-g7",
  "mac": "08:00:27:c3:fb:76",
  "ip": "192.168.1.143",
  "ts": "2026-11-23T19:45:00Z",
  "cpu_pct": 12.5,
  "mem": { "total_mb": 3936, "usada_mb": 1210, "pct": 30.7 },
  "disco": [ { "montaje": "/", "pct": 45 } ],
  "carga": [0.12, 0.30, 0.25],
  "uptime_s": 3600,
  "top_procesos": [
    { "pid": 1234, "cmd": "firefox-esr", "cpu": 5.1 }
  ]
}
```

### 6.3 Alerta por cambio de umbral o caída (`canal: "alertas"`)
```json
{
  "canal": "alertas",
  "tipo": "alerta_recurso",
  "host": "kali-g7",
  "ts": "2026-11-23T19:46:15Z",
  "estado_anterior": "OK",
  "estado_actual": "CRITICO",
  "motivo": "CPU 96.4% (> 85%)",
  "cpu_pct": 96.4,
  "mem_pct": 41.2,
  "disco_pct": 23
}
```

---

## 7. Guion para la demo en vivo (3–4 min)

1. **Verificación y arranque de agentes (45 s):** Mostrar `shellcheck agente.sh panel.sh` limpio y ejecutar `./agente.sh -i 5 -H kali-g7` (y en otros 2 equipos/terminales con `-H kali-g7-n2` y `-H kali-g7-n3`).
2. **Panel en terminal y vista web 3D (1 min):** Ejecutar `./panel.sh --html --servir 8080` y abrir `http://localhost:8080/` para enseñar tanto la tabla ANSI en terminal como las tarjetas 3D isométricas, los KPIs y la mini-gráfica `▁▂▃▄▅▆▇█`.
3. **Provocar pico de CPU y alerta (1 min):** En otra terminal lanzar cualquiera de estas dos opciones:
   ```bash
   # Opción A (sin instalar paquetes extra)
   yes > /dev/null &
   YES_PID=$!
   # Esperar <15s: la CPU pasa a rojo, el prisma 3D sube y se publica alerta en canal "alertas"
   kill "$YES_PID"

   # Opción B (con stress-ng)
   stress-ng --cpu 2 --timeout 60
   ```
4. **Simular caída y cierre limpio (45 s):** Parar uno de los agentes con `Ctrl+C`; pasados `30s` el panel lo marca en rojo como `CAÍDO` y publica la transición `OK -> CAIDO` en `alertas`. Finalizar el panel con `Ctrl+C` mostrando el cierre limpio del servidor HTTP en segundo plano.
