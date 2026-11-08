#!/bin/bash
# ==============================================================================
#               BLUE COMPANY • CLOUD NETWORK MANAGER
#           Sistema Corporativo de Gestión SSH / WS / UDP
#                        Edición: ENTERPRISE v9.0 HARDENED
# ==============================================================================
# VERSION_TAG="9.0"
# REPO_URL="https://github.com/david-bluecompany/blue-company"
# RAW_SCRIPT_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/main/BLUECOMPANY.sh"
# RAW_VERSION_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/main/VERSION"
# ==============================================================================

# Auto-elevación a root si se ejecuta sin sudo
if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# MODO PROTEGIDO: no se permite reconfigurar servicios, firewall ni red automáticamente.
BLUECOMPANY_SAFE_MODE=1
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ------------------------------------------------------------------------------
# CONSTANTES DE VERSIÓN, RUTAS Y ARCHIVOS DEL SISTEMA
# ------------------------------------------------------------------------------
VERSION_SCRIPT="9.0.1-hardened"
EDICION_SCRIPT="ENTERPRISE v9.0 HARDENED"
GITHUB_REPO_URL="https://github.com/david-bluecompany/blue-company"
GITHUB_RAW_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/main/BLUECOMPANY.sh"
GITHUB_VERSION_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/main/VERSION"

BIN_TARGET="/usr/local/bin/adm-ssh"
BIN_ALIAS="/usr/local/bin/blue"

DB_LIMITS="/etc/ssh-limits.txt"
BACKUP_FILE="/root/backup-clientes-blue.tar.gz"
BACKUP_DIR="/var/backups/bluecompany"
CONF_DIR="/etc/bluecompany"
LOG_DIR="/var/log/bluecompany"

VERSION_LOCAL_FILE="${CONF_DIR}/version.info"
BLOCKED_USERS_DB="${CONF_DIR}/blocked_users.db"
BLOCKED_IPS_DB="${CONF_DIR}/blocked_ips.db"
WHITELIST_IPS_DB="${CONF_DIR}/whitelist_ips.db"

LOCKS_LOG="${LOG_DIR}/locks.log"
AUDIT_LOG="${LOG_DIR}/admin_audit.log"
SECURITY_LOG="${LOG_DIR}/security.log"

PANEL_LOCK="/run/bluecompany-panel.lock"
UPDATE_LOCK="/run/bluecompany-update.lock"
MONITOR_LOCK="/run/bluecompany-monitor.lock"
UPDATE_CACHE="/run/bluecompany-update.cache"

# ------------------------------------------------------------------------------
# AUTO-INSTALACIÓN TRANSPARENTE SI SE EJECUTA COMO INSTALADOR EXTERNO
# ------------------------------------------------------------------------------
inicializar_entorno_seguro() {
    # Inicialización limitada a archivos propios de BLUE COMPANY.
    # No modifica SSH, Dropbear, /etc/shells, cron, firewall, sysctl ni servicios externos.
    install -d -m 700 "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR"
    for f in "$DB_LIMITS" "$BLOCKED_USERS_DB" "$BLOCKED_IPS_DB" "$WHITELIST_IPS_DB" "$LOCKS_LOG" "$AUDIT_LOG" "$SECURITY_LOG"; do
        [ -e "$f" ] || install -m 600 /dev/null "$f"
        chmod 600 "$f" 2>/dev/null || true
    done
    [ -e "$VERSION_LOCAL_FILE" ] || printf '%s\n' "$VERSION_SCRIPT" > "$VERSION_LOCAL_FILE"
    chmod 600 "$VERSION_LOCAL_FILE" 2>/dev/null || true

}

# Modo instalación silenciosa por parámetro (--install-only)
if [ "${1:-}" = "--install-only" ]; then
    inicializar_entorno_seguro || exit 1
    install -m 755 "$(readlink -f "$0")" "$BIN_TARGET" || exit 1
    ln -sfn "$BIN_TARGET" "$BIN_ALIAS"
    echo "[OK] Panel instalado en ${BIN_TARGET} (comando: blue o adm-ssh). No se modificaron servicios externos."
    exit 0
fi

# Protección contra ejecuciones duplicadas del panel en la misma sesión o colisión administrativa
exec 9>"$PANEL_LOCK"
if ! flock -n 9; then
    echo -e "\033[1;33m[!] Ya existe otra instancia activa de BLUE COMPANY ejecutándose en este servidor (PID: $(cat "$PANEL_LOCK" 2>/dev/null)).\033[0m"
    echo -e "\033[0;90mSi deseas forzar el acceso, cierra la otra terminal SSH o espera a que finalice.\033[0m"
    exit 1
fi
echo "$$" >&9

inicializar_entorno_seguro

# ------------------------------------------------------------------------------
# PALETA DE COLORES CORPORATIVA BLUE COMPANY
# ------------------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_NEON='\033[38;5;39m'
C_BBLUE='\033[48;5;17m\033[1;37m'
C_BHEADER='\033[48;5;24m\033[1;37m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_WHITE='\033[1;37m'
C_GRAY='\033[0;90m'

# ------------------------------------------------------------------------------
# AUDITORÍA, REGISTROS Y VALIDACIÓN DE ENTRADAS
# ------------------------------------------------------------------------------
registrar_accion_admin() {
    local accion="$1"
    local detalle="$2"
    local fecha ip_admin
    fecha=$(date "+%Y-%m-%d %H:%M:%S")
    ip_admin=$(echo "${SSH_CLIENT:-LOCAL}" | awk '{print $1}')
    echo "${fecha} | ADMIN_IP:${ip_admin} | ${accion} | ${detalle}" >> "$AUDIT_LOG"
    chmod 600 "$AUDIT_LOG" 2>/dev/null
}

registrar_bloqueo_usuario() {
    local u="$1"
    local motivo="$2"
    local fecha
    fecha=$(date "+%Y-%m-%d %H:%M:%S")
    echo "${fecha}|${u}|${motivo}" >> "$LOCKS_LOG"
    sed -i "/^${u}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
    echo "${u}|${fecha}|${motivo}" >> "$BLOCKED_USERS_DB"
    chmod 600 "$LOCKS_LOG" "$BLOCKED_USERS_DB" 2>/dev/null
}

validar_nombre_usuario() {
    local u="$1"
    [[ "$u" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]
}

validar_entero_positivo() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]
}

# Hash SHA-512-crypt para no guardar contraseñas en texto claro en la base local.
hashear_contrasena() {
    local clave="$1" salt hash
    command -v openssl >/dev/null 2>&1 || return 1
    salt=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$salt" ] || return 1
    hash=$(openssl passwd -6 -salt "$salt" "$clave" 2>/dev/null) || return 1
    [[ "$hash" == '$6$'* ]] || return 1
    printf '%s' "$hash"
}

validar_ip_v4() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -r o1 o2 o3 o4 <<< "$ip"
        [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ]
        return $?
    fi
    return 1
}

asegurar_dependencia() {
    local bin="$1"
    local pkg="$2"
    if ! command -v "$bin" &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y &>/dev/null
        apt-get install -y "$pkg" &>/dev/null
    fi
}

# ------------------------------------------------------------------------------
# MIGRACIÓN AUTOMÁTICA Y UTILIDADES DE TIEMPO / BLOQUEO INDIVIDUAL
# ------------------------------------------------------------------------------
migrar_db_limites() {
    [ ! -s "$DB_LIMITS" ] && return
    local tmp_db="/tmp/.ssh_limits_mig.$$"
    local cambiado=0
    > "$tmp_db"

    while IFS=':' read -r u lim clave exp_ep estado_manual _ <&3; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        # Conservar registros aunque la cuenta del sistema no exista todavía.
        # La sincronización de cuentas se realiza solo mediante acciones explícitas.
        [[ ! "$lim" =~ ^[0-9]+$ || "$lim" -le 0 ]] && lim=1
        if [[ ! "$exp_ep" =~ ^[0-9]+$ ]]; then
            local exp_raw
            exp_raw=$(chage -l "$u" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
            if [ -n "$exp_raw" ] && [ "$exp_raw" != "never" ]; then
                exp_ep=$(date -d "$exp_raw 23:59:59" +%s 2>/dev/null || echo 0)
            else
                exp_ep=0
            fi
            cambiado=1
        fi
        [ -z "$estado_manual" ] && estado_manual="ACTIVO"
        echo "${u}:${lim}:${clave}:${exp_ep}:${estado_manual}" >> "$tmp_db"
    done 3< "$DB_LIMITS"

    if [ "$cambiado" -eq 1 ]; then
        mv -f "$tmp_db" "$DB_LIMITS"
        chmod 600 "$DB_LIMITS"
    else
        rm -f "$tmp_db"
    fi
}

calcular_duracion() {
    local entrada="$1"
    entrada=$(echo "$entrada" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -z "$entrada" ] && entrada="30d"

    local valor segs texto
    if [[ "$entrada" =~ ^([0-9]+)m$ ]]; then
        valor="${BASH_REMATCH[1]}"
        [ "$valor" -le 0 ] && valor=30
        segs=$(( valor * 60 ))
        texto="${valor} min"
    elif [[ "$entrada" =~ ^([0-9]+)h$ ]]; then
        valor="${BASH_REMATCH[1]}"
        [ "$valor" -le 0 ] && valor=1
        segs=$(( valor * 3600 ))
        texto="${valor} horas"
    elif [[ "$entrada" =~ ^([0-9]+)d?$ ]]; then
        valor="${BASH_REMATCH[1]}"
        [ "$valor" -le 0 ] && valor=30
        segs=$(( valor * 86400 ))
        texto="${valor} días"
    else
        segs=$(( 30 * 86400 ))
        texto="30 días"
    fi
    echo "${segs}|${texto}"
}

bloquear_cuenta_sistema() {
    local u="$1"
    local motivo="${2:-BLOQUEO DE SISTEMA}"
    expulsar_sesiones_usuario "$u"
    usermod -L -s /bin/false -e 1970-01-02 "$u" 2>/dev/null
    passwd -l "$u" &>/dev/null
    registrar_bloqueo_usuario "$u" "$motivo"
}

desbloquear_cuenta_sistema() {
    local u="$1"
    local clave="$2"
    local exp_ep="$3"
    local f_chage
    f_chage=$(date -d "@$(( exp_ep + 86400 ))" +%Y-%m-%d 2>/dev/null || date -d "+30 days" +%Y-%m-%d)
    usermod -U -s /bin/false -e "$f_chage" "$u" 2>/dev/null
    passwd -u "$u" &>/dev/null
    if [ -n "$clave" ] && [ "$clave" != "(Sin registro)" ]; then
        if [[ "$clave" == '$6$'* || "$clave" == '$5$'* || "$clave" == '$y$'* ]]; then
            echo "${u}:${clave}" | chpasswd -e 2>/dev/null
        else
            echo "${u}:${clave}" | chpasswd 2>/dev/null
        fi
    fi
    sed -i "/^${u}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
}

verificar_y_bloquear_vencidos_ahora() {
    [ ! -s "$DB_LIMITS" ] && return
    local ahora
    ahora=$(date +%s)
    while IFS=':' read -r u lim clave exp_ep estado_manual _ <&3; do
        [[ -z "$u" || "$u" =~ ^# ]] && continue
        id "$u" &>/dev/null || continue
        local debe_bloquear=0
        local razon_bloqueo=""
        if [ "$estado_manual" = "SUSPENDIDO" ]; then
            debe_bloquear=1
            razon_bloqueo="SUSPENSIÓN ADMINISTRATIVA"
        elif [ "$estado_manual" = "BLOQUEADO_LIMITE" ]; then
            debe_bloquear=1
            razon_bloqueo="EXCESO DE LÍMITE DE CONEXIONES"
        elif [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ] && [ "$ahora" -ge "$exp_ep" ]; then
            debe_bloquear=1
            razon_bloqueo="FECHA DE VENCIMIENTO EXPIRADA"
        fi
        if [ "$debe_bloquear" -eq 1 ]; then
            local sh_actual
            sh_actual=$(getent passwd "$u" | cut -d: -f7)
            if [ "$sh_actual" != "/bin/false" ]; then
                bloquear_cuenta_sistema "$u" "$razon_bloqueo"
            fi
        fi
    done 3< "$DB_LIMITS"
}

# ------------------------------------------------------------------------------
# MÉTRICAS DEL SERVIDOR (IP / CPU / RAM / TRÁFICO RED)
# ------------------------------------------------------------------------------
obtener_ip() {
    local cache_file="/tmp/.vps_public_ip"
    local ip=""
    if [ -s "$cache_file" ]; then
        ip=$(cat "$cache_file" 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s --max-time 2 https://api.ipify.org || curl -s --max-time 2 https://icanhazip.com | tr -d '[:space:]')
        if validar_ip_v4 "$ip"; then
            echo "$ip" > "$cache_file"
        else
            ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            [ -z "$ip" ] && ip="127.0.0.1"
        fi
    fi
    echo "$ip"
}

obtener_uso_cpu() {
    local a b c idle1 e f g idle2 total1 total2 diff_idle diff_total uso
    read -r _ a b c idle1 e f g _ < /proc/stat
    total1=$((a + b + c + idle1 + e + f + g))
    sleep 0.10
    read -r _ a b c idle2 e f g _ < /proc/stat
    total2=$((a + b + c + idle2 + e + f + g))
    diff_idle=$((idle2 - idle1))
    diff_total=$((total2 - total1))
    if [ "$diff_total" -gt 0 ]; then
        uso=$(( (100 * (diff_total - diff_idle)) / diff_total ))
    else
        uso=0
    fi
    echo "${uso}%"
}

obtener_info_ram_gb() {
    awk '
        /^MemTotal:/ { total_kb = $2 }
        /^MemFree:/ { free_kb = $2 }
        /^Buffers:/ { buf_kb = $2 }
        /^Cached:/ { cache_kb = $2 }
        /^MemAvailable:/ { avail_kb = $2 }
        END {
            if (total_kb <= 0) total_kb = 1;
            if (avail_kb <= 0) avail_kb = free_kb + buf_kb + cache_kb;
            used_kb = total_kb - avail_kb;
            if (used_kb < 0) used_kb = 0;

            total_gb = total_kb / 1048576;
            libre_gb = avail_kb / 1048576;
            porc = int((used_kb * 100) / total_kb);

            printf "%.2f GB|%.2f GB|%d%%", libre_gb, total_gb, porc
        }
    ' /proc/meminfo
}

obtener_trafico_red_gb() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    [ -z "$iface" ] && iface=$(awk -F: 'NR>2 && $1 !~ /lo/ {gsub(/ /,"",$1); print $1; exit}' /proc/net/dev)
    awk -v dev="$iface" '
        $1 ~ "^"dev":" {
            sub(/^[^:]+:/, "", $0)
            rx = $1 / 1073741824
            tx = $9 / 1073741824
            printf "%.2f GB|%.2f GB", rx, tx
            found=1
            exit
        }
        END {
            if (!found) printf "0.00 GB|0.00 GB"
        }
    ' /proc/net/dev
}

# ------------------------------------------------------------------------------
# MOTOR DE DETECCIÓN EN VIVO (OPENSSH + DROPBEAR + METADATOS IP/TIEMPO/CONSUMO)
# ------------------------------------------------------------------------------
obtener_mapa_dropbear() {
    if command -v python3 &>/dev/null; then
        python3 - "$DB_LIMITS" 2>/dev/null << 'PYEOF'
import os, sys, re, subprocess

db_file = sys.argv[1]
cache_file = "/run/blue-dropbear.map"
users = []
if os.path.exists(db_file):
    with open(db_file, "r", errors="ignore") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and ":" in line:
                u = line.split(":", 1)[0].strip()
                if u:
                    users.append(u)

users.sort(key=len, reverse=True)

all_pids = []
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    try:
        with open(f"/proc/{entry}/comm", "r") as f:
            comm = f.read().strip().lower()
        if "dropbear" not in comm:
            continue
        with open(f"/proc/{entry}/stat", "r") as f:
            stat_after = f.read().rsplit(")", 1)[-1].split()
            ppid = int(stat_after[1])
        if ppid > 1:
            all_pids.append(entry)
    except Exception:
        continue

if not all_pids:
    sys.exit(0)

mapped = {}

if os.path.exists(cache_file):
    try:
        with open(cache_file, "r", errors="ignore") as cf:
            for line in cf:
                if ":" in line:
                    p, usr = line.strip().split(":", 1)
                    if p in all_pids:
                        mapped[p] = usr
    except Exception:
        pass

if len(mapped) < len(all_pids):
    log_text = ""
    for lf in ["/var/log/auth.log.1", "/var/log/auth.log", "/var/log/syslog", "/var/log/secure"]:
        if os.path.exists(lf):
            try:
                with open(lf, "r", errors="ignore") as f:
                    f.seek(0, os.SEEK_END)
                    sz = f.tell()
                    f.seek(max(0, sz - 250000))
                    log_text += f.read() + "\n"
            except Exception:
                pass

    try:
        j_out = subprocess.check_output(
            ["journalctl", "-u", "dropbear", "--no-pager", "-n", "1000"],
            stderr=subprocess.DEVNULL
        ).decode(errors="ignore")
        log_text += j_out
    except Exception:
        pass

    pat = re.compile(r"dropbear\[(\d+)\]:.*succeeded for ['\"]?([^'\"\s]+)['\"]?", re.IGNORECASE)
    for m in pat.finditer(log_text):
        p, usr = m.group(1), m.group(2)
        if p in all_pids:
            mapped[p] = usr

for pid in all_pids:
    if pid in mapped:
        continue
    try:
        with open(f"/proc/{pid}/maps", "r") as mf, open(f"/proc/{pid}/mem", "rb", 0) as mem:
            for line in mf:
                if "rw-p" not in line:
                    continue
                parts = line.split()[0].split("-")
                start, end = int(parts[0], 16), int(parts[1], 16)
                if end - start > 8 * 1024 * 1024:
                    continue
                mem.seek(start)
                chunk = mem.read(end - start)
                for u in users:
                    ub = re.escape(u.encode())
                    if re.search(rb"/home/" + ub + rb"\x00(?!/)", chunk) or (b"succeeded for '" + u.encode() + b"'" in chunk):
                        mapped[pid] = u
                        break
                if pid in mapped:
                    break
    except Exception:
        pass

for pid, usr in mapped.items():
    print(f"{pid}:{usr}")
PYEOF
        return
    fi
}

# Devuelve PIDs individuales pertenecientes ÚNICAMENTE a un usuario
obtener_pids_usuario() {
    local u="$1"
    local mapa_db="$2"
    local pids_ssh pids_db

    pids_ssh=$(ps -u "$u" -o pid=,comm= 2>/dev/null | awk '$2 ~ /^sshd/ {print $1}')
    if [ -z "$pids_ssh" ]; then
        pids_ssh=$(ps -eo pid=,user=,args= 2>/dev/null | awk -v usr="$u" '$2=="root" && $0 ~ "sshd(-session)?: " usr "(\\[priv\\]|@notty|$)" {print $1}')
    fi

    if [ -n "$mapa_db" ]; then
        pids_db=$(printf "%s\n" "$mapa_db" | awk -F':' -v usr="$u" '$2 == usr {print $1}')
    fi

    printf "%s\n%s\n" "$pids_ssh" "$pids_db" | awk 'NF>0 {print $1}' | sort -u
}

contar_conexiones_usuario() {
    local u="$1"
    local mapa_db="$2"

    local n_ssh=0
    n_ssh=$(ps -u "$u" -o comm= 2>/dev/null | grep -cE '^sshd')
    if [ "$n_ssh" -eq 0 ]; then
        n_ssh=$(ps -eo user=,args= 2>/dev/null | awk -v usr="$u" '$1=="root" && $0 ~ "sshd(-session)?: " usr "(\\[priv\\]|@notty|$)" {c++} END {print c+0}')
    fi

    local n_db=0
    if [ -n "$mapa_db" ]; then
        n_db=$(printf "%s\n" "$mapa_db" | awk -F':' -v usr="$u" '$2 == usr {c++} END {print c+0}')
    fi

    echo $(( n_ssh + n_db ))
}

# Expulsión estrictamente individual: NUNCA mata procesos globales de sshd, dropbear ni xray
expulsar_sesiones_usuario() {
    local u="$1"
    [ -z "$u" ] || [ "$u" = "root" ] && return 1
    # Modo conservador: no mata procesos ni sesiones activas.
    # Bloquear la cuenta evita nuevas autenticaciones; las sesiones existentes
    # se mantienen para no interrumpir conexiones o procesos ajenos.
    return 0
}

# Obtiene IP, tiempo conectado y consumo (bytes IO/Socket) de los procesos del usuario
obtener_telemetria_usuario() {
    local u="$1"
    local mapa_db="$2"
    local pids
    pids=$(obtener_pids_usuario "$u" "$mapa_db")
    if [ -z "$pids" ]; then
        echo "-|-|0 B"
        return
    fi

    local ip_cli="-"
    local etime_max="-"
    local bytes_total=0

    # Extraer conexiones de red asociadas a los PIDs del usuario
    local ss_out
    ss_out=$(ss -tnp 2>/dev/null)

    for p in $pids; do
        [ ! -d "/proc/$p" ] && continue

        # Tiempo de sesión del primer/mayor proceso activo
        if [ "$etime_max" = "-" ]; then
            etime_max=$(ps -p "$p" -o etime= 2>/dev/null | xargs)
            [ -z "$etime_max" ] && etime_max="00:01"
        fi

        # IP del cliente desde ss o logs si viene por loopback despachador
        local ip_cand
        ip_cand=$(printf "%s\n" "$ss_out" | grep "pid=${p}," | awk '{print $5}' | sed 's/::ffff://g' | cut -d: -f1 | grep -vE '^127\.' | head -n 1)
        if [ -n "$ip_cand" ]; then
            ip_cli="$ip_cand"
        fi

        # Lectura de consumo I/O del proceso (rchar + wchar en /proc/<pid>/io)
        if [ -r "/proc/$p/io" ]; then
            local b_proc
            b_proc=$(awk '/^(rchar|wchar):/ {sum += $2} END {print sum+0}' "/proc/$p/io" 2>/dev/null)
            bytes_total=$(( bytes_total + b_proc ))
        fi
    done

    # Si entró vía Despachador WS (loopback 127.x.y.z), buscar IP externa en puerto 80 o auth.log
    if [ "$ip_cli" = "-" ]; then
        ip_cli=$(printf "%s\n" "$ss_out" | awk '$4 ~ /:80$/ {print $5}' | sed 's/::ffff://g' | cut -d: -f1 | grep -vE '^127\.' | head -n 1)
        [ -z "$ip_cli" ] && ip_cli="WS-Tunel(P:80)"
    fi

    local consumo_txt
    consumo_txt=$(awk -v b="$bytes_total" 'BEGIN {
        if (b <= 0) printf "N/D";
        else if (b < 1048576) printf "%.1f KB", b / 1024;
        else if (b < 1073741824) printf "%.2f MB", b / 1048576;
        else printf "%.2f GB", b / 1073741824;
    }')

    echo "${ip_cli}|${etime_max}|${consumo_txt}"
}

# ------------------------------------------------------------------------------
# COMPROBADOR DE ACTUALIZACIONES DESDE GITHUB (DETECCIÓN SILENCIOSA + MANUAL)
# ------------------------------------------------------------------------------
extraer_version_remota() {
    local v_remota=""
    # 1. Intentar leer archivo VERSION dedicado
    v_remota=$(curl -sL --max-time 3 "$GITHUB_VERSION_URL" 2>/dev/null | head -n 1 | tr -d '[:space:]vV')
    if [[ ! "$v_remota" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        # 2. Extraer desde etiqueta VERSION_SCRIPT o VERSION_TAG en BLUECOMPANY.sh
        local cab
        cab=$(curl -sL --max-time 4 "$GITHUB_RAW_URL" 2>/dev/null | head -n 60)
        v_remota=$(printf "%s\n" "$cab" | grep -E '^(# *VERSION_TAG=|VERSION_SCRIPT=)' | head -n 1 | cut -d'"' -f2 | tr -d '[:space:]vV')
    fi
    echo "$v_remota"
}

comparar_versiones_mayor() {
    # Retorna 0 (true) si $1 (remota) es estrictamente mayor que $2 (local)
    local v_rem="$1"
    local v_loc="$2"
    [[ ! "$v_rem" =~ ^[0-9]+\.[0-9]+ ]] && return 1
    [ "$v_rem" = "$v_loc" ] && return 1
    local mayor
    mayor=$(printf "%s\n%s\n" "$v_loc" "$v_rem" | sort -V | tail -n 1)
    [ "$mayor" = "$v_rem" ]
}

verificar_actualizacion_cache() {
    local ahora mtime=0
    ahora=$(date +%s)
    if [ -f "$UPDATE_CACHE" ]; then
        mtime=$(stat -c %Y "$UPDATE_CACHE" 2>/dev/null || echo 0)
    fi
    if [ $(( ahora - mtime )) -gt 600 ]; then
        (
            local vr
            vr=$(extraer_version_remota)
            if [[ "$vr" =~ ^[0-9]+\.[0-9]+ ]]; then
                echo "$vr" > "$UPDATE_CACHE"
            fi
        ) &>/dev/null &
    fi
    if [ -s "$UPDATE_CACHE" ]; then
        cat "$UPDATE_CACHE" 2>/dev/null
    else
        echo "$VERSION_SCRIPT"
    fi
}

# ------------------------------------------------------------------------------
# ENCABEZADO CORPORATIVO BLUE COMPANY v9.0 ENTERPRISE
# ------------------------------------------------------------------------------
generar_banner() {
    local ip cpu ram_data ram_libre ram_total ram_porc net_data rx_gb tx_gb
    local c_ssh s_ssh c_db s_db c_ws s_ws c_udp s_udp c_lim s_lim c_tcp s_tcp cc_actual
    local total_reg=0 v_remota

    ip=$(obtener_ip)
    cpu=$(obtener_uso_cpu)
    ram_data=$(obtener_info_ram_gb)
    IFS='|' read -r ram_libre ram_total ram_porc <<< "$ram_data"
    net_data=$(obtener_trafico_red_gb)
    IFS='|' read -r rx_gb tx_gb <<< "$net_data"
    v_remota=$(verificar_actualizacion_cache)

    if [ -s "$DB_LIMITS" ]; then
        total_reg=$(grep -cvE '^(#|$)' "$DB_LIMITS" 2>/dev/null || echo 0)
    fi

    if pgrep -x "sshd" &>/dev/null; then
        c_ssh="$C_GREEN"; s_ssh="ON"
    else
        c_ssh="$C_RED";   s_ssh="OFF"
    fi

    if pgrep -x "dropbear" &>/dev/null; then
        c_db="$C_GREEN";  s_db="ON"
    else
        c_db="$C_RED";    s_db="OFF"
    fi

    if systemctl is-active --quiet despachador 2>/dev/null || pgrep -f "despachador.py" &>/dev/null; then
        c_ws="$C_GREEN";  s_ws="ON"
    else
        c_ws="$C_RED";    s_ws="OFF"
    fi

    if pgrep -f "badvpn-udpgw" &>/dev/null; then
        c_udp="$C_GREEN"; s_udp="ON"
    else
        c_udp="$C_RED";   s_udp="OFF"
    fi

    if systemctl is-active --quiet blue-limiter 2>/dev/null || pgrep -f "blue-limiter.py" &>/dev/null; then
        c_lim="$C_GREEN"; s_lim="ON"
    else
        c_lim="$C_RED";   s_lim="OFF"
    fi

    cc_actual=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$cc_actual" = "bbr" ] || [ -f /etc/sysctl.d/99-bluecompany-tcp.conf ]; then
        c_tcp="$C_GREEN"; s_tcp="BBR + LowLatency"
    else
        c_tcp="$C_YELLOW"; s_tcp="Estándar"
    fi

    echo -e "${C_BLUE}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BLUE}║${C_BBLUE}        BLUE COMPANY • CLOUD NETWORK MANAGER          ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}║${C_BHEADER}       Sistema Corporativo SSH/WS • ENTERPRISE v9.0   ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}IP Servidor:${C_RESET} ${C_WHITE}%-19s${C_RESET} ${C_CYAN}CPU Uso:${C_RESET} ${C_YELLOW}%-10s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$ip" "$cpu"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}RAM Libre  :${C_RESET} ${C_GREEN}%-11s${C_RESET} ${C_CYAN}Total:${C_RESET} ${C_WHITE}%-10s${C_RESET} ${C_YELLOW}(%-4s)${C_RESET}   ${C_BLUE}║${C_RESET}\n" "$ram_libre" "$ram_total" "$ram_porc"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}Tráfico RX :${C_RESET} ${C_GREEN}%-19s${C_RESET} ${C_CYAN}TX Sub.:${C_RESET} ${C_YELLOW}%-10s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$rx_gb" "$tx_gb"
    printf "${C_BLUE}║${C_RESET} ${C_CYAN}Motor TCP  :${C_RESET} ${c_tcp}%-19s${C_RESET} ${C_CYAN}Cuentas:${C_RESET} ${C_WHITE}%-10s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$s_tcp" "$total_reg"
    echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
    printf "${C_BLUE}║${C_RESET} ${C_WHITE}SSH:${C_RESET}${c_ssh}%-3s${C_RESET} │ ${C_WHITE}DB:${C_RESET}${c_db}%-3s${C_RESET} │ ${C_WHITE}WS80:${C_RESET}${c_ws}%-3s${C_RESET} │ ${C_WHITE}UDP:${C_RESET}${c_udp}%-3s${C_RESET} │ ${C_WHITE}AUTO-LIM:${C_RESET}${c_lim}%-3s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$s_ssh" "$s_db" "$s_ws" "$s_udp" "$s_lim"
    if comparar_versiones_mayor "$v_remota" "$VERSION_SCRIPT"; then
        echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
        printf "${C_BLUE}║${C_RESET} ${C_YELLOW}[!] ACTUALIZACIÓN DISPONIBLE EN GITHUB: v%-11s${C_RESET} ${C_BLUE}║${C_RESET}\n" "$v_remota"
    fi
    echo -e "${C_BLUE}╚══════════════════════════════════════════════════════╝${C_RESET}"
}

mostrar_pantalla_encabezado() {
    # La apertura del panel es de solo lectura respecto a las cuentas existentes.
    local b
    b=$(generar_banner)
    clear
    echo -e "$b"
}

imprimir_ticket_cliente() {
    local u="$1"
    local c="$2"
    local lim="$3"
    local f_exp="$4"
    local ip
    ip=$(obtener_ip)

    echo -e "${C_BLUE}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BLUE}║${C_BBLUE}         CREDENCIALES DE ACCESO • BLUE COMPANY        ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}╠══════════════════════════════════════════════════════╣${C_RESET}"
    echo -e "  ${C_CYAN}Servidor / IP :${C_RESET} ${C_WHITE}$ip${C_RESET}"
    echo -e "  ${C_CYAN}Usuario       :${C_RESET} ${C_GREEN}$u${C_RESET}"
    echo -e "  ${C_CYAN}Contraseña    :${C_RESET} ${C_GREEN}$c${C_RESET}"
    echo -e "  ${C_CYAN}Vencimiento   :${C_RESET} ${C_YELLOW}$f_exp${C_RESET}"
    echo -e "  ${C_CYAN}Dispositivos  :${C_RESET} ${C_YELLOW}Máximo $lim simultáneos${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Puertos WS    :${C_RESET} ${C_WHITE}80, 8080, 8880 (HTTP / WebSocket)${C_RESET}"
    echo -e "  ${C_CYAN}Puerto Directo:${C_RESET} ${C_WHITE}2222 (Dropbear) │ 22 (OpenSSH)${C_RESET}"
    echo -e "  ${C_CYAN}Puerto Juegos :${C_RESET} ${C_GREEN}7300 (BadVPN UDPGW)${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Payload Estándar :${C_RESET}"
    echo -e "  ${C_GRAY}GET / HTTP/1.1[crlf]Host: $ip[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]${C_RESET}"
    echo -e "  ${C_CYAN}Payload Split    :${C_RESET}"
    echo -e "  ${C_GRAY}GET / HTTP/1.1[crlf][split]Host: $ip[crlf]Upgrade: websocket[crlf][crlf]${C_RESET}"
    echo -e "${C_BLUE}╚══════════════════════════════════════════════════════╝${C_RESET}"
}

formatear_tiempo_restante() {
    local exp_ep="$1"
    local ahora="$2"
    if [[ ! "$exp_ep" =~ ^[0-9]+$ ]] || [ "$exp_ep" -le 0 ]; then
        echo "Ilim."
        return
    fi
    local diff=$(( exp_ep - ahora ))
    if [ "$diff" -le 0 ]; then
        echo "0m"
    elif [ "$diff" -lt 3600 ]; then
        echo "$(( (diff + 59) / 60 ))m"
    elif [ "$diff" -lt 86400 ]; then
        local h=$(( diff / 3600 ))
        local m=$(( (diff % 3600) / 60 ))
        echo "${h}h ${m}m"
    else
        local d=$(( diff / 86400 ))
        local h=$(( (diff % 86400) / 3600 ))
        echo "${d}d ${h}h"
    fi
}

# ==============================================================================
# CATEGORÍA 1: GESTIÓN COMERCIAL
# ==============================================================================

crear_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───────── ALTA DE CLIENTE O DEMO EN 1-CLICK ──────────┐${C_RESET}"
    echo -e "  ${C_GRAY}(Presiona ENTER vacío para generar una DEMO rápida)${C_RESET}"
    read -r -p "  ► Nombre de Usuario  : " usuario
    usuario=$(echo "$usuario" | tr -d ' ')

    local clave entrada_tiempo limite

    if [ -z "$usuario" ]; then
        local rnd
        rnd=$(shuf -i 1000-9999 -n 1 2>/dev/null || echo $(( RANDOM % 9000 + 1000 )))
        usuario="demo${rnd}"
        while id "$usuario" &>/dev/null; do
            rnd=$(( RANDOM % 9000 + 1000 ))
            usuario="demo${rnd}"
        done
        clave="1234"
        limite=1
        read -r -p "  ► Duración Demo [30m]: " entrada_tiempo
        [ -z "$entrada_tiempo" ] && entrada_tiempo="30m"
    else
        if ! validar_nombre_usuario "$usuario"; then
            echo -e "\n${C_RED}  [!] Usa solo letras, números, guiones (-) o (_) [máx 32 caract.].${C_RESET}"
            read -r -p "  Presiona Enter para continuar..."
            return
        fi

        if id "$usuario" &>/dev/null; then
            echo -e "\n${C_RED}  [!] El cliente '$usuario' ya existe en el servidor.${C_RESET}"
            read -r -p "  Presiona Enter para continuar..."
            return
        fi

        read -r -p "  ► Contraseña [1234]  : " clave
        [ -z "$clave" ] && clave="1234"
        clave=$(echo "$clave" | tr -d ':')

        echo -e "  ${C_GRAY}(Ej: 30 para días, 2h para horas, 30m para demo)${C_RESET}"
        read -r -p "  ► Tiempo de servicio : " entrada_tiempo
        [ -z "$entrada_tiempo" ] && entrada_tiempo="30d"

        read -r -p "  ► Límite dispositivos: " limite
        if ! validar_entero_positivo "$limite"; then
            limite=1
        fi
    fi

    local info_t segs txt_dur exp_epoch f_chage fecha_legible
    info_t=$(calcular_duracion "$entrada_tiempo")
    IFS='|' read -r segs txt_dur <<< "$info_t"

    exp_epoch=$(( $(date +%s) + segs ))
    f_chage=$(date -d "@$(( exp_epoch + 86400 ))" +%Y-%m-%d)
    fecha_legible=$(date -d "@$exp_epoch" "+%Y-%m-%d %H:%M")

    if ! useradd -M -s /bin/false -e "$f_chage" "$usuario" 2>/dev/null; then
        echo -e "\n${C_RED}  [!] Error al registrar el usuario en el sistema.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi

    if ! echo "${usuario}:${clave}" | chpasswd; then
        userdel "$usuario" 2>/dev/null
        echo -e "\n${C_RED}  [!] No se pudo establecer la contraseña; alta cancelada.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi
    local clave_hash
    clave_hash=$(hashear_contrasena "$clave") || {
        userdel "$usuario" 2>/dev/null
        echo -e "\n${C_RED}  [!] No se pudo generar el hash seguro. Alta revertida; no se guardó en la base.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    }
    sed -i "/^${usuario}:/d" "$DB_LIMITS"
    echo "${usuario}:${limite}:${clave_hash}:${exp_epoch}:ACTIVO" >> "$DB_LIMITS"
    chmod 600 "$DB_LIMITS"

    registrar_accion_admin "CREAR_USUARIO" "Usuario=${usuario} Limite=${limite} Duracion=${txt_dur}"

    if ! systemctl is-active --quiet blue-limiter 2>/dev/null; then
        instalar_limitador_auto "1" &>/dev/null
    fi

    clear
    imprimir_ticket_cliente "$usuario" "$clave" "$limite" "$fecha_legible ($txt_dur)"
    read -r -p "  Presiona Enter para volver al panel..."
}

renovar_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────── RENOVACIÓN INTELIGENTE DE SUSCRIPCIÓN ────────┐${C_RESET}"

    read -r -p "  ► Cliente a renovar: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi

    local linea_actual lim_actual clave_actual exp_actual ahora base_epoch modo_suma=""
    ahora=$(date +%s)
    linea_actual=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    lim_actual=$(echo "$linea_actual" | cut -d: -f2)
    clave_actual=$(echo "$linea_actual" | cut -d: -f3)
    exp_actual=$(echo "$linea_actual" | cut -d: -f4)
    [[ ! "$lim_actual" =~ ^[0-9]+$ || "$lim_actual" -le 0 ]] && lim_actual=1
    [[ ! "$exp_actual" =~ ^[0-9]+$ ]] && exp_actual=0

    echo -e "  ${C_GRAY}(Ej: 30 para días, 2h para horas, 30m para demo)${C_RESET}"
    read -r -p "  ► Tiempo a agregar : " entrada_tiempo
    local info_t segs txt_dur exp_epoch fecha_legible
    info_t=$(calcular_duracion "$entrada_tiempo")
    IFS='|' read -r segs txt_dur <<< "$info_t"

    if [ "$exp_actual" -gt "$ahora" ]; then
        base_epoch="$exp_actual"
        modo_suma=" (Sumado a su saldo vigente)"
    else
        base_epoch="$ahora"
    fi

    exp_epoch=$(( base_epoch + segs ))
    fecha_legible=$(date -d "@$exp_epoch" "+%Y-%m-%d %H:%M")

    desbloquear_cuenta_sistema "$usuario" "$clave_actual" "$exp_epoch"
    if [[ "$clave_actual" != '$6$'* && "$clave_actual" != '$5$'* && "$clave_actual" != '$y$'* && -n "$clave_actual" ]]; then
        clave_actual=$(hashear_contrasena "$clave_actual") || {
            echo -e "  ${C_RED}[!] No se pudo proteger la contraseña antigua; no se modificó el registro.${C_RESET}"
            read -r -p "  Presiona Enter para volver..."
            return
        }
    fi

    sed -i "/^${usuario}:/d" "$DB_LIMITS"
    echo "${usuario}:${lim_actual}:${clave_actual}:${exp_epoch}:ACTIVO" >> "$DB_LIMITS"

    registrar_accion_admin "RENOVAR_USUARIO" "Usuario=${usuario} TiempoAgregado=${txt_dur} NuevoVencimiento=${fecha_legible}"

    echo -e "\n${C_GREEN}  [✓] Cliente '$usuario' activo hasta: $fecha_legible (+${txt_dur})${modo_suma}.${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

modificar_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────── MODIFICAR CREDENCIALES / LÍMITE / TIEMPO ─────┐${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Modificar Contraseña o Límite de Dispositivos"
    echo -e "  ${C_WHITE}[2]${C_RESET} Renovar / Sumar Tiempo a Suscripción"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " sub_op

    if [ "$sub_op" = "2" ]; then
        renovar_usuario
        return
    elif [ "$sub_op" != "1" ]; then
        return
    fi

    read -r -p "  ► Nombre del cliente: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi

    local linea_actual lim_actual clave_actual exp_actual est_actual
    linea_actual=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    lim_actual=$(echo "$linea_actual" | cut -d: -f2)
    clave_actual=$(echo "$linea_actual" | cut -d: -f3)
    exp_actual=$(echo "$linea_actual" | cut -d: -f4)
    est_actual=$(echo "$linea_actual" | cut -d: -f5)
    [[ ! "$lim_actual" =~ ^[0-9]+$ ]] && lim_actual=1
    [[ ! "$exp_actual" =~ ^[0-9]+$ ]] && exp_actual=$(( $(date +%s) + 2592000 ))
    [ -z "$clave_actual" ] && clave_actual="(Sin registro)"
    [ -z "$est_actual" ] && est_actual="ACTIVO"

    echo -e "  ${C_GRAY}(Deja en blanco para conservar el valor actual)${C_RESET}"
    read -r -p "  ► Nueva contraseña [Actual conservada]: " nueva_clave
    if [ -n "$nueva_clave" ]; then
        nueva_clave=$(echo "$nueva_clave" | tr -d ':')
        if ! echo "${usuario}:${nueva_clave}" | chpasswd; then
            echo -e "  ${C_RED}[!] No se pudo actualizar la contraseña.${C_RESET}"
            read -r -p "  Presiona Enter para volver..."
            return
        fi
        clave_actual=$(hashear_contrasena "$nueva_clave") || {
            passwd -l "$usuario" 2>/dev/null
            echo -e "  ${C_RED}[!] Falló el hash seguro; cuenta bloqueada por precaución.${C_RESET}"
            read -r -p "  Presiona Enter para volver..."
            return
        }
        echo -e "  ${C_GREEN}[✓] Contraseña actualizada y almacenada como hash.${C_RESET}"
    fi

    read -r -p "  ► Nuevo límite disp. [$lim_actual]: " nuevo_limite
    if validar_entero_positivo "$nuevo_limite"; then
        lim_actual="$nuevo_limite"
        echo -e "  ${C_GREEN}[✓] Límite actualizado a $lim_actual dispositivos.${C_RESET}"
    fi

    if [[ "$clave_actual" != '$6$'* && "$clave_actual" != '$5$'* && "$clave_actual" != '$y$'* && "$clave_actual" != "(Sin registro)" && -n "$clave_actual" ]]; then
        clave_actual=$(hashear_contrasena "$clave_actual") || {
            echo -e "  ${C_RED}[!] No se pudo convertir la contraseña antigua a hash; registro no modificado.${C_RESET}"
            read -r -p "  Presiona Enter para volver..."
            return
        }
    fi
    sed -i "/^${usuario}:/d" "$DB_LIMITS"
    echo "${usuario}:${lim_actual}:${clave_actual}:${exp_actual}:${est_actual}" >> "$DB_LIMITS"

    registrar_accion_admin "MODIFICAR_USUARIO" "Usuario=${usuario} NuevoLimite=${lim_actual}"
    read -r -p "  Presiona Enter para volver..."
}

eliminar_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_RED}┌────────────── BAJA Y PURGA DE CLIENTES ──────────────┐${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Eliminar un Cliente Específico"
    echo -e "  ${C_YELLOW}[2]${C_RESET} Purgar Automáticamente Todas las Cuentas Vencidas"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_del

    if [ "$op_del" = "2" ]; then
        eliminar_vencidos
        return
    elif [ "$op_del" != "1" ]; then
        return
    fi

    read -r -p "  ► Cliente a eliminar: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null || [ "$usuario" = "root" ]; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe o no es válido.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi

    read -r -p "  ¿Confirmas dar de baja a '$usuario'? (s/n): " confirm
    if [[ "$confirm" =~ ^[sS]$ ]]; then
        expulsar_sesiones_usuario "$usuario"
        userdel -rf "$usuario" 2>/dev/null
        sed -i "/^${usuario}:/d" "$DB_LIMITS"
        sed -i "/^${usuario}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
        registrar_accion_admin "ELIMINAR_USUARIO" "Usuario=${usuario}"
        echo -e "\n${C_GREEN}  [✓] Cliente '$usuario' eliminado del sistema.${C_RESET}"
    else
        echo -e "\n${C_YELLOW}  [!] Operación cancelada.${C_RESET}"
    fi
    read -r -p "  Presiona Enter para volver..."
}

eliminar_vencidos() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────────── PURGA DE CUENTAS EXPIRADAS ───────────────┐${C_RESET}"
    local borrados=0
    local hoy_epoch
    hoy_epoch=$(date +%s)

    if [ -s "$DB_LIMITS" ]; then
        local lista_borrar=()
        while IFS=':' read -r u limite clave exp_ep _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            if ! id "$u" &>/dev/null; then
                lista_borrar+=("$u")
                continue
            fi
            if [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ] && [ "$hoy_epoch" -ge "$exp_ep" ]; then
                lista_borrar+=("$u")
            fi
        done 3< "$DB_LIMITS"

        for u in "${lista_borrar[@]}"; do
            expulsar_sesiones_usuario "$u"
            userdel -rf "$u" 2>/dev/null
            sed -i "/^${u}:/d" "$DB_LIMITS"
            sed -i "/^${u}|/d" "$BLOCKED_USERS_DB" 2>/dev/null
            echo -e "  ${C_RED}✖ Cuenta expirada eliminada definitivamente:${C_RESET} $u"
            borrados=$(( borrados + 1 ))
        done
    fi

    if [ "$borrados" -eq 0 ]; then
        echo -e "\n  ${C_GREEN}[✓] No hay cuentas vencidas pendientes por eliminar.${C_RESET}"
    else
        registrar_accion_admin "PURGAR_VENCIDOS" "TotalEliminados=${borrados}"
        echo -e "\n  ${C_GREEN}[✓] Se eliminaron $borrados cuentas vencidas del servidor.${C_RESET}"
    fi
    read -r -p "  Presiona Enter para volver..."
}

controlar_acceso_usuario() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────── BLOQUEAR, DESBLOQUEAR Y REINTEGRAR CLIENTE ────┐${C_RESET}"

    read -r -p "  ► Nombre del cliente: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi

    local linea lim clave exp_ep est_manual
    linea=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    lim=$(echo "$linea" | cut -d: -f2)
    clave=$(echo "$linea" | cut -d: -f3)
    exp_ep=$(echo "$linea" | cut -d: -f4)
    est_manual=$(echo "$linea" | cut -d: -f5)
    [[ ! "$lim" =~ ^[0-9]+$ ]] && lim=1
    [[ ! "$exp_ep" =~ ^[0-9]+$ ]] && exp_ep=$(( $(date +%s) + 2592000 ))
    [ -z "$est_manual" ] && est_manual="ACTIVO"

    echo -e "  ${C_CYAN}Estado actual de '$usuario':${C_RESET} ${C_YELLOW}${est_manual}${C_RESET}"
    echo -e ""
    echo -e "  ${C_WHITE}[1]${C_RESET} Solo expulsar sesiones activas individuales ahora (Kick)"
    echo -e "  ${C_YELLOW}[2]${C_RESET} Bloquear / Suspender cliente temporalmente"
    echo -e "  ${C_GREEN}[3]${C_RESET} Desbloquear y Reintegrar cliente (Reactivar acceso)"
    echo -e "  ${C_GRAY}[0] Cancelar${C_RESET}"
    read -r -p "  ► Opción: " op_k

    case "$op_k" in
        1)
            local mapa_db activas
            mapa_db=$(obtener_mapa_dropbear)
            activas=$(contar_conexiones_usuario "$usuario" "$mapa_db")
            expulsar_sesiones_usuario "$usuario"
            registrar_accion_admin "EXPULSAR_SESIONES" "Usuario=${usuario} SesionesCerradas=${activas}"
            echo -e "\n${C_GREEN}  [✓] Se cerraron únicamente las conexiones activas ($activas) de '$usuario'.${C_RESET}"
            ;;
        2)
            read -r -p "  ► Motivo del bloqueo [Suspensión administrativa]: " motivo_b
            [ -z "$motivo_b" ] && motivo_b="Suspensión administrativa"
            bloquear_cuenta_sistema "$usuario" "$motivo_b"
            sed -i "/^${usuario}:/d" "$DB_LIMITS"
            echo "${usuario}:${lim}:${clave}:${exp_ep}:SUSPENDIDO" >> "$DB_LIMITS"
            registrar_accion_admin "BLOQUEAR_USUARIO" "Usuario=${usuario} Motivo=${motivo_b}"
            echo -e "\n${C_YELLOW}  [⏸] Cliente '$usuario' bloqueado individualmente (Motivo: $motivo_b).${C_RESET}"
            ;;
        3)
            if [ "$(date +%s)" -ge "$exp_ep" ]; then
                echo -e "\n${C_YELLOW}  [!] La fecha del cliente había expirado. Se otorgarán +30 días al reintegrar o puedes renovarlo.${C_RESET}"
                read -r -p "  ¿Deseas reintegrarlo sumando 30 días ahora? (s/n): " conf_r
                if [[ "$conf_r" =~ ^[sS]$ ]]; then
                    exp_ep=$(( $(date +%s) + 2592000 ))
                else
                    return
                fi
            fi
            desbloquear_cuenta_sistema "$usuario" "$clave" "$exp_ep"
            sed -i "/^${usuario}:/d" "$DB_LIMITS"
            echo "${usuario}:${lim}:${clave}:${exp_ep}:ACTIVO" >> "$DB_LIMITS"
            registrar_accion_admin "REINTEGRAR_USUARIO" "Usuario=${usuario} Estado=ACTIVO"
            echo -e "\n${C_GREEN}  [✓] Cliente '$usuario' desbloqueado y reintegrado exitosamente.${C_RESET}"
            ;;
        *) return ;;
    esac
    read -r -p "  Presiona Enter para volver..."
}

consultar_vencimientos() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────── AUDITORÍA DE VENCIMIENTOS Y FICHAS ───────────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-14s %-18s %-11s %-12s${C_RESET}\n" "USUARIO" "FECHA VENCIMIENTO" "RESTANTE" "ESTADO"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

    local ahora
    ahora=$(date +%s)
    if [ ! -s "$DB_LIMITS" ]; then
        echo -e "  ${C_YELLOW}No hay clientes registrados.${C_RESET}"
    else
        while IFS=':' read -r u lim clave exp_ep est_manual _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            id "$u" &>/dev/null || continue
            local f_txt rest_txt est_col
            if [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ]; then
                f_txt=$(date -d "@$exp_ep" "+%Y-%m-%d %H:%M")
                rest_txt=$(formatear_tiempo_restante "$exp_ep" "$ahora")
            else
                f_txt="Ilimitado"
                rest_txt="Ilim."
            fi

            if [ "$est_manual" = "SUSPENDIDO" ] || [ "$est_manual" = "BLOQUEADO_LIMITE" ]; then
                est_col="${C_YELLOW}${est_manual}${C_RESET}"
            elif [ "$rest_txt" = "0m" ]; then
                est_col="${C_RED}VENCIDO${C_RESET}"
            else
                est_col="${C_GREEN}ACTIVO${C_RESET}"
            fi
            printf " ${C_WHITE}%-14s${C_RESET} %-18s ${C_YELLOW}%-11s${C_RESET} %b\n" "$u" "$f_txt" "$rest_txt" "$est_col"
        done 3< "$DB_LIMITS"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_WHITE}[F]${C_RESET} Ver Ficha / Ticket Completo de un Cliente   ${C_GRAY}[ENTER] Volver${C_RESET}"
    read -r -p "  ► Selección: " op_v
    if [[ "$op_v" =~ ^[fF]$ ]]; then
        ver_ficha_cliente
    fi
}

ver_ficha_cliente() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌─────────── CONSULTAR FICHA DE CLIENTE ───────────────┐${C_RESET}"

    read -r -p "  ► Nombre del cliente: " usuario
    if [ -z "$usuario" ] || ! id "$usuario" &>/dev/null; then
        echo -e "\n${C_RED}  [!] El cliente '$usuario' no existe.${C_RESET}"
        read -r -p "  Presiona Enter para continuar..."
        return
    fi

    local linea lim clave exp_ep est_manual exp_txt ahora rest_txt
    ahora=$(date +%s)
    linea=$(grep -E "^${usuario}:" "$DB_LIMITS" 2>/dev/null | tail -n 1)
    lim=$(echo "$linea" | cut -d: -f2)
    clave=$(echo "$linea" | cut -d: -f3)
    exp_ep=$(echo "$linea" | cut -d: -f4)
    est_manual=$(echo "$linea" | cut -d: -f5)
    [[ ! "$lim" =~ ^[0-9]+$ ]] && lim=1
    [ -z "$clave" ] && clave="(Asignada previamente)"

    if [[ "$exp_ep" =~ ^[0-9]+$ ]] && [ "$exp_ep" -gt 0 ]; then
        exp_txt=$(date -d "@$exp_ep" "+%Y-%m-%d %H:%M")
        if [ "$est_manual" = "SUSPENDIDO" ] || [ "$est_manual" = "BLOQUEADO_LIMITE" ]; then
            exp_txt="$exp_txt ($est_manual)"
        elif [ "$ahora" -ge "$exp_ep" ]; then
            exp_txt="$exp_txt (VENCIDO / BLOQUEADO)"
        else
            rest_txt=$(formatear_tiempo_restante "$exp_ep" "$ahora")
            exp_txt="$exp_txt (Restan: $rest_txt)"
        fi
    else
        exp_txt="Ilimitado"
    fi

    clear
    imprimir_ticket_cliente "$usuario" "$clave" "$lim" "$exp_txt"
    read -r -p "  Presiona Enter para volver..."
}

consultar_limites_clientes() {
    mostrar_pantalla_encabezado
    local mapa_db
    mapa_db=$(obtener_mapa_dropbear)

    echo -e "${C_NEON}┌─────────── CONSULTA DE LÍMITES Y CAPACIDAD ──────────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-15s %-12s %-12s %-14s${C_RESET}\n" "USUARIO" "CONECTADOS" "LÍMITE MAX" "DISPONIBILIDAD"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

    if [ ! -s "$DB_LIMITS" ]; then
        echo -e "  ${C_YELLOW}No hay clientes registrados.${C_RESET}"
    else
        while IFS=':' read -r u lim _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            id "$u" &>/dev/null || continue
            [[ ! "$lim" =~ ^[0-9]+$ ]] && lim=1
            local act disp_txt
            act=$(contar_conexiones_usuario "$u" "$mapa_db")
            if [ "$act" -gt "$lim" ]; then
                disp_txt="${C_RED}EXCEDIDO (+$(( act - lim )))${C_RESET}"
            elif [ "$act" -eq "$lim" ]; then
                disp_txt="${C_YELLOW}COMPLETO (0 libres)${C_RESET}"
            else
                disp_txt="${C_GREEN}$(( lim - act )) libres${C_RESET}"
            fi
            printf " ${C_WHITE}%-15s${C_RESET} ${C_YELLOW}%-12s${C_RESET} %-12s %b\n" "$u" "$act" "$lim" "$disp_txt"
        done 3< "$DB_LIMITS"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

# ==============================================================================
# CATEGORÍA 2: MONITOREO Y SEGURIDAD
# ==============================================================================

listar_usuarios_en_vivo() {
    # Evitar ejecuciones simultáneas del monitor en la misma instancia
    exec 8>"$MONITOR_LOCK"
    if ! flock -n 8; then
        echo -e "\n  ${C_YELLOW}[!] El monitor en tiempo real ya está abierto en otra sesión.${C_RESET}"
        read -r -p "  Presiona Enter para volver..."
        return
    fi

    while true; do
        verificar_y_bloquear_vencidos_ahora
        local b mapa_db
        b=$(generar_banner)
        mapa_db=$(obtener_mapa_dropbear)

        clear
        echo -e "$b"
        echo -e "${C_NEON}  MONITOR INTELIGENTE DE USUARIOS EN TIEMPO REAL (2s)${C_RESET}"
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        printf "${C_BOLD}${C_CYAN} %-11s %-15s %-7s %-8s %-9s %-10s${C_RESET}\n" "USUARIO" "IP CLIENTE" "SES/LIM" "TIEMPO" "CONSUMO" "ESTADO"
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

        local total_online=0
        local total_conex=0
        local hoy_epoch
        hoy_epoch=$(date +%s)

        if [ ! -s "$DB_LIMITS" ]; then
            echo -e "  ${C_YELLOW}No hay clientes registrados en la base de datos.${C_RESET}"
        else
            while IFS=':' read -r u limite clave exp_ep est_manual _ <&3; do
                [[ -z "$u" || "$u" =~ ^# ]] && continue
                id "$u" &>/dev/null || continue

                [[ ! "$limite" =~ ^[0-9]+$ ]] && limite=1
                local activas dias_txt sh_usr tele ip_u t_con cons_u estado conex_txt
                activas=$(contar_conexiones_usuario "$u" "$mapa_db")
                total_conex=$(( total_conex + activas ))
                [ "$activas" -gt 0 ] && total_online=$(( total_online + 1 ))

                dias_txt=$(formatear_tiempo_restante "$exp_ep" "$hoy_epoch")
                sh_usr=$(getent passwd "$u" | cut -d: -f7)

                if [ "$activas" -gt 0 ]; then
                    tele=$(obtener_telemetria_usuario "$u" "$mapa_db")
                    IFS='|' read -r ip_u t_con cons_u <<< "$tele"
                else
                    ip_u="-"
                    t_con="-"
                    cons_u="-"
                fi

                if [ "$est_manual" = "SUSPENDIDO" ] || [ "$est_manual" = "BLOQUEADO_LIMITE" ]; then
                    estado="${C_YELLOW}⏸ Bloq.${C_RESET}"
                elif [ "$dias_txt" = "0m" ] || [ "$sh_usr" = "/bin/false" ]; then
                    estado="${C_RED}✖ Vencido${C_RESET}"
                elif [ "$activas" -gt "$limite" ]; then
                    estado="${C_RED}▲ Excedido${C_RESET}"
                elif [ "$activas" -gt 0 ]; then
                    estado="${C_GREEN}● Online${C_RESET}"
                else
                    estado="${C_GRAY}○ Inactivo${C_RESET}"
                fi

                conex_txt="${activas}/${limite}"
                printf " ${C_WHITE}%-11.11s${C_RESET} %-15.15s ${C_YELLOW}%-7s${C_RESET} %-8.8s %-9.9s %b\n" "$u" "$ip_u" "$conex_txt" "$t_con" "$cons_u" "$estado"
            done 3< "$DB_LIMITS"
        fi

        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        echo -e " ${C_CYAN}Clientes Conectados:${C_RESET} ${C_GREEN}$total_online${C_RESET}  │  ${C_CYAN}Túneles Activos:${C_RESET} ${C_YELLOW}$total_conex${C_RESET}"
        echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
        echo -e " ${C_YELLOW}[B]${C_RESET} Bloquear individualmente excedidos   ${C_RED}[Q / ENTER]${C_RESET} Salir"

        if read -r -t 2 -n 1 tecla; then
            if [[ "$tecla" =~ ^[bB]$ ]]; then
                local bloqueados_ahora=0
                while IFS=':' read -r u limite clave exp_ep est_manual _ <&3; do
                    [[ -z "$u" || "$u" =~ ^# ]] && continue
                    id "$u" &>/dev/null || continue
                    local act
                    act=$(contar_conexiones_usuario "$u" "$mapa_db")
                    if [ "$act" -gt "$limite" ]; then
                        local mot="EXCESO DE LÍMITE DETECTADO (${act}/${limite} sesiones)"
                        bloquear_cuenta_sistema "$u" "$mot"
                        sed -i "/^${u}:/d" "$DB_LIMITS"
                        echo "${u}:${limite}:${clave}:${exp_ep}:BLOQUEADO_LIMITE" >> "$DB_LIMITS"
                        bloqueados_ahora=$(( bloqueados_ahora + 1 ))
                    fi
                done 3< "$DB_LIMITS"
                echo -e "\n ${C_GREEN}[✓] Se bloquearon individualmente $bloqueados_ahora usuarios que superaban su límite.${C_RESET}"
                sleep 1.5
            else
                break
            fi
        fi
    done
    flock -u 8 2>/dev/null
}

monitor_consumo_usuarios() {
    mostrar_pantalla_encabezado
    local mapa_db
    mapa_db=$(obtener_mapa_dropbear)

    echo -e "${C_NEON}┌───────── MONITOR DE CONSUMO DE DATOS Y SESIÓN ───────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-14s %-9s %-14s %-16s${C_RESET}\n" "USUARIO" "SESIONES" "TIEMPO ACTIVO" "TRÁFICO SESIÓN"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

    local hay_datos=0
    if [ -s "$DB_LIMITS" ]; then
        while IFS=':' read -r u limite _ <&3; do
            [[ -z "$u" || "$u" =~ ^# ]] && continue
            id "$u" &>/dev/null || continue
            local act tele ip_u t_con cons_u
            act=$(contar_conexiones_usuario "$u" "$mapa_db")
            tele=$(obtener_telemetria_usuario "$u" "$mapa_db")
            IFS='|' read -r ip_u t_con cons_u <<< "$tele"
            printf " ${C_WHITE}%-14s${C_RESET} ${C_YELLOW}%-9s${C_RESET} %-14s ${C_GREEN}%-16s${C_RESET}\n" "$u" "${act}/${limite}" "$t_con" "$cons_u"
            hay_datos=1
        done 3< "$DB_LIMITS"
    fi
    [ "$hay_datos" -eq 0 ] && echo -e "  ${C_YELLOW}No hay usuarios registrados para medir consumo.${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

gestion_bloqueos_automaticos() {
    mostrar_pantalla_encabezado
    local est_lim="${C_RED}INACTIVO${C_RESET}"
    if systemctl is-active --quiet blue-limiter 2>/dev/null; then
        est_lim="${C_GREEN}ACTIVO 24/7 (Vigilancia individual cada 3s)${C_RESET}"
    fi

    echo -e "${C_NEON}┌────── CONTROL DE BLOQUEOS AUTOMÁTICOS Y LÍMITES ─────┐${C_RESET}"
    echo -e "  Demonio Auto-Limitador: $est_lim"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Usuarios actualmente bloqueados:${C_RESET}"
    if [ ! -s "$BLOCKED_USERS_DB" ]; then
        echo -e "  ${C_GREEN}✓ Ningún usuario bloqueado en este momento.${C_RESET}"
    else
        while IFS='|' read -r bu bf bm; do
            [ -z "$bu" ] && continue
            echo -e "  ${C_RED}● $bu${C_RESET} │ ${C_GRAY}$bf${C_RESET} │ ${C_YELLOW}$bm${C_RESET}"
        done < "$BLOCKED_USERS_DB"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Desbloquear y Reintegrar un Usuario Bloqueado"
    echo -e "  ${C_WHITE}[2]${C_RESET} Activar / Actualizar Motor Auto-Limitador 24/7"
    echo -e "  ${C_WHITE}[3]${C_RESET} Detener Motor Auto-Limitador"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_ba

    case "$op_ba" in
        1) controlar_acceso_usuario ;;
        2) instalar_limitador_auto ;;
        3)
            echo -e "  ${C_YELLOW}[!] Acción protegida: el panel no detendrá ni deshabilitará servicios existentes.${C_RESET}"
            read -r -p "  Presiona Enter para volver..."
            ;;
        *) return ;;
    esac
}

consultar_historial_sistema() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────── HISTORIAL DE BLOQUEOS Y AUDITORÍA ADMIN ───────┐${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Consultar Historial de Bloqueos de Usuarios (Fecha/Hora/Motivo)"
    echo -e "  ${C_WHITE}[2]${C_RESET} Consultar Historial de Acciones Administrativas"
    echo -e "  ${C_WHITE}[3]${C_RESET} Consultar Registro de Eventos de Seguridad (IPs)"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_h

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    case "$op_h" in
        1)
            echo -e "${C_CYAN}  ÚLTIMOS BLOQUEOS DE USUARIOS REGISTRADOS:${C_RESET}"
            if [ -s "$LOCKS_LOG" ]; then
                tail -n 25 "$LOCKS_LOG" | awk -F'|' '{printf "  \033[0;90m%s\033[0m │ \033[1;37m%-12s\033[0m │ \033[1;33m%s\033[0m\n", $1, $2, $3}'
            else
                echo -e "  ${C_GREEN}Sin registros de bloqueos hasta la fecha.${C_RESET}"
            fi
            ;;
        2)
            echo -e "${C_CYAN}  HISTORIAL DE ACCIONES ADMINISTRATIVAS:${C_RESET}"
            if [ -s "$AUDIT_LOG" ]; then
                tail -n 25 "$AUDIT_LOG" | sed 's/^/  /'
            else
                echo -e "  ${C_GRAY}Sin acciones registradas.${C_RESET}"
            fi
            ;;
        3)
            echo -e "${C_CYAN}  REGISTRO DE SEGURIDAD E IPs BLOQUEADAS:${C_RESET}"
            if [ -s "$SECURITY_LOG" ]; then
                tail -n 25 "$SECURITY_LOG" | sed 's/^/  /'
            else
                echo -e "  ${C_GREEN}Sin incidentes de seguridad registrados.${C_RESET}"
            fi
            ;;
        *) return ;;
    esac
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

centro_seguridad_vps() {
    mostrar_pantalla_encabezado
    local ip_admin_actual
    ip_admin_actual=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
    if validar_ip_v4 "$ip_admin_actual"; then
        grep -qxF "$ip_admin_actual" "$WHITELIST_IPS_DB" 2>/dev/null || echo "$ip_admin_actual" >> "$WHITELIST_IPS_DB"
    fi

    local estado_bt="${C_YELLOW}INACTIVO${C_RESET}"
    if iptables -L FORWARD -n 2>/dev/null | grep -q "BitTorrent" || iptables -L OUTPUT -n 2>/dev/null | grep -q "BitTorrent"; then
        estado_bt="${C_GREEN}PROTEGIDO (ACTIVO)${C_RESET}"
    fi

    local total_ips_bloq=0
    [ -s "$BLOCKED_IPS_DB" ] && total_ips_bloq=$(grep -cvE '^(#|$)' "$BLOCKED_IPS_DB" 2>/dev/null || echo 0)

    echo -e "${C_NEON}┌────── CENTRO DE SEGURIDAD Y PROTECCIÓN BRUTE-FORCE ──┐${C_RESET}"
    echo -e "  Tu IP Admin Protegida (Whitelist): ${C_GREEN}${ip_admin_actual:-Sesión Local}${C_RESET}"
    echo -e "  Escudo Anti-Torrent / P2P        : $estado_bt"
    echo -e "  IPs Bloqueadas por Fuerza Bruta  : ${C_YELLOW}${total_ips_bloq}${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Detectar Intentos de Acceso Sospechosos (Fuerza Bruta)"
    echo -e "  ${C_WHITE}[2]${C_RESET} Bloquear IP Atacante con Comprobación Segura"
    echo -e "  ${C_WHITE}[3]${C_RESET} Ver / Desbloquear IPs Registradas en Lista Negra"
    echo -e "  ${C_WHITE}[4]${C_RESET} Activar / Desactivar Escudo Anti-Torrent (Kernel)"
    echo -e "  ${C_WHITE}[5]${C_RESET} Verificar y Blindar Permisos de Archivos Sensibles"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_sec

    case "$op_sec" in
        1)
            echo -e "\n  ${C_CYAN}[*] Analizando registros de autenticación en busca de ataques...${C_RESET}"
            local log_src=""
            [ -f /var/log/auth.log ] && log_src="/var/log/auth.log"
            [ -z "$log_src" ] && [ -f /var/log/secure ] && log_src="/var/log/secure"

            if [ -n "$log_src" ]; then
                grep -Ei "Failed password|Invalid user|bad password attempt" "$log_src" 2>/dev/null | \
                 grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
                 grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | \
                 sort | uniq -c | sort -nr | head -n 10 | \
                 awk '{printf "  \033[1;31m%-8s intentos\033[0m │ IP: \033[1;37m%s\033[0m\n", $1, $2}'
            else
                journalctl -u ssh -u dropbear --no-pager -n 1000 2>/dev/null | \
                 grep -Ei "Failed password|Invalid user|bad password" | \
                 grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.' | \
                 sort | uniq -c | sort -nr | head -n 10 | \
                 awk '{printf "  \033[1;31m%-8s intentos\033[0m │ IP: \033[1;37m%s\033[0m\n", $1, $2}'
            fi
            ;;
        2)
            echo -e "  ${C_YELLOW}[!] Bloqueo de IP deshabilitado: no se tocará el firewall ni se arriesgará tu acceso.${C_RESET}"
            ;;
        3)
            echo -e "  ${C_YELLOW}[!] Gestión de bloqueos IP deshabilitada en modo protegido; no se modificará el firewall.${C_RESET}"
            ;;
        4)
            echo -e "  ${C_YELLOW}[!] Reglas anti-torrent deshabilitadas: no se modificarán reglas iptables.${C_RESET}"
            ;;
        5)
            chmod 600 "$DB_LIMITS" "$BLOCKED_USERS_DB" "$BLOCKED_IPS_DB" "$WHITELIST_IPS_DB" "$LOCKS_LOG" "$AUDIT_LOG" "$SECURITY_LOG" 2>/dev/null
            chmod 700 "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null
            chmod 755 "$BIN_TARGET" 2>/dev/null
            echo -e "\n  ${C_GREEN}[✓] Permisos estrictos (600/700) aplicados a bases de datos, backups y logs.${C_RESET}"
            ;;
        *) return ;;
    esac
    read -r -p "  Presiona Enter para volver..."
}

escudo_y_mantenimiento_vps() {
    echo -e "  ${C_YELLOW}[!] No se alteran reglas iptables, caché del kernel ni servicios externos desde el panel protegido. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

estado_servicios_diferenciado() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───── ESTADO DE SERVICIOS (BLUE COMPANY vs EXTERNOS) ─┐${C_RESET}"
    echo -e "  ${C_CYAN}1. SERVICIOS ADMINISTRADOS POR BLUE COMPANY:${C_RESET}"

    local s_list=("ssh:OpenSSH Server (P:22)" "dropbear:Dropbear SSH (P:2222)" "despachador:Despachador Multiplexor WS (P:80/8080/8880)" "badvpn:BadVPN UDPGW (P:7300)" "blue-limiter:Auto-Limitador Inteligente 24/7")
    for item in "${s_list[@]}"; do
        local srv="${item%%:*}"
        local desc="${item#*:}"
        local st_txt="${C_RED}● DETENIDO${C_RESET}"
        if [ "$srv" = "ssh" ]; then
            pgrep -x "sshd" &>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        elif [ "$srv" = "dropbear" ]; then
            pgrep -x "dropbear" &>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        elif [ "$srv" = "badvpn" ]; then
            pgrep -f "badvpn-udpgw" &>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        else
            systemctl is-active --quiet "$srv" 2>/dev/null && st_txt="${C_GREEN}● ACTIVO${C_RESET}"
        fi
        printf "   %-44s %b\n" "$desc" "$st_txt"
    done

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}2. SERVICIOS EXTERNOS (SOLO LECTURA - NO MODIFICADOS):${C_RESET}"
    local ext_list=("xray:Xray Core (VLESS/VMess/Trojan)" "x-ui:Panel 3x-ui / x-ui" "nginx:Servidor Web Nginx" "hysteria-server:Hysteria 2 UDP" "cron:Demonio de Tareas Cron")
    for item in "${ext_list[@]}"; do
        local srv="${item%%:*}"
        local desc="${item#*:}"
        local st_txt="${C_GRAY}○ No instalado / Inactivo${C_RESET}"
        if systemctl is-active --quiet "$srv" 2>/dev/null || pgrep -x "${srv%%-*}" &>/dev/null; then
            st_txt="${C_GREEN}● ACTIVO (Protegido)${C_RESET}"
        fi
        printf "   %-44s %b\n" "$desc" "$st_txt"
    done
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

puertos_en_escucha_vps() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───────── PUERTOS EN ESCUCHA Y CLASIFICACIÓN ─────────┐${C_RESET}"
    printf "${C_BOLD}${C_CYAN} %-7s %-9s %-18s %-20s${C_RESET}\n" "PROTO" "PUERTO" "PROCESO" "ORIGEN / GESTIÓN"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

    ss -tulnp 2>/dev/null | awk 'NR>1 {
        proto = $1
        split($5, a, ":")
        port = a[length(a)]
        proc = $7
        gsub(/users:\(\("/, "", proc)
        gsub(/".*/, "", proc)
        if (proc == "") proc = "kernel/sistema"
        if (port ~ /^(22|80|2222|7300)$|despachador|dropbear|badvpn/) {
            origen = "\033[1;36mBLUE COMPANY\033[0m"
        } else {
            origen = "\033[1;33mEXTERNO (Respetado)\033[0m"
        }
        printf " %-7s %-9s %-18.18s %s\n", proto, port, proc, origen
    }' | sort -u

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "8080,8880"; then
        echo -e "  ${C_GREEN}✓ Redirección NAT Activa:${C_RESET} Puertos 8080, 8880 -> Puerto 80 (Despachador)"
    else
        echo -e "  ${C_YELLOW}! Redirección NAT 8080/8880:${C_RESET} No detectada"
    fi
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

monitor_cpu_ram_procesos() {
    mostrar_pantalla_encabezado
    local cpu_u load_avg
    cpu_u=$(obtener_uso_cpu)
    load_avg=$(awk '{print $1 " (1m) | " $2 " (5m) | " $3 " (15m)"}' /proc/loadavg 2>/dev/null)

    echo -e "${C_NEON}┌───────── RENDIMIENTO DE CPU, RAM Y PROCESOS ─────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Uso Actual CPU :${C_RESET} ${C_YELLOW}$cpu_u${C_RESET}"
    echo -e "  ${C_CYAN}Carga Sistema  :${C_RESET} ${C_WHITE}$load_avg${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}ESTADO DETALLADO DE MEMORIA RAM Y SWAP:${C_RESET}"
    free -h | awk '
        NR==1 {printf "  \033[1;36m%-10s %-10s %-10s %-10s %-10s\033[0m\n", "TIPO", "TOTAL", "USADO", "LIBRE", "DISPONIBLE"}
        NR==2 {printf "  %-10s %-10s %-10s %-10s %-10s\n", "RAM:", $2, $3, $4, $7}
        NR==3 {printf "  %-10s %-10s %-10s %-10s\n", "SWAP:", $2, $3, $4}
    '
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}TOP 8 PROCESOS QUE CONSUMEN MÁS RECURSOS:${C_RESET}"
    printf "${C_BOLD}${C_CYAN}  %-8s %-10s %-7s %-7s %-20s${C_RESET}\n" "PID" "USUARIO" "%CPU" "%MEM" "COMANDO"
    ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu,-%mem 2>/dev/null | awk 'NR>1 && NR<=9 {printf "  %-8s %-10.10s %-7s %-7s %-20.20s\n", $1, $2, $3, $4, $5}'
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

diagnostico_integral_vps() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌────────── DIAGNÓSTICO INTEGRAL DEL SERVIDOR ─────────┐${C_RESET}"
    echo -e "  ${C_CYAN}1. ESPACIO DISPONIBLE EN DISCO E INODOS:${C_RESET}"
    df -h / | awk 'NR==2 {printf "   Partición Raíz (/): Usado %s de %s (Disponible: \033[1;32m%s\033[0m - Uso: %s)\n", $3, $2, $4, $5}'
    df -i / | awk 'NR==2 {printf "   Uso de Inodos (/) : %s usados (%s disponible)\n", $5, $4}'

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}2. SALUD DE COMPONENTES BLUE COMPANY:${C_RESET}"
    local sh_ok="${C_GREEN}OK${C_RESET}"
    grep -qxF "/bin/expired" /etc/shells 2>/dev/null && sh_ok="${C_RED}ALERTA (/bin/expired en /etc/shells)${C_RESET}"
    echo -e "   Seguridad de Shells (/etc/shells): $sh_ok"
    echo -e "   Base de Datos ($DB_LIMITS) : $( [ -r "$DB_LIMITS" ] && echo -e "${C_GREEN}Legible ($(wc -l < "$DB_LIMITS") registros)${C_RESET}" || echo -e "${C_RED}No encontrada${C_RESET}" )"
    echo -e "    Demonio Limitador (blue-limiter) : $( systemctl is-active --quiet blue-limiter && echo -e "${C_GREEN}ACTIVO${C_RESET}" || echo -e "${C_RED}DETENIDO${C_RESET}" )"
    echo -e "   Multiplexor WS (despachador.py)  : $( systemctl is-active --quiet despachador && echo -e "${C_GREEN}ACTIVO${C_RESET}" || echo -e "${C_RED}DETENIDO${C_RESET}" )"
    echo -e "   Dropbear SSH (Puerto 2222)       : $( pgrep -x dropbear &>/dev/null && echo -e "${C_GREEN}ACTIVO${C_RESET}" || echo -e "${C_RED}DETENIDO${C_RESET}" )"
    echo -e "   Xray / 3x-ui (Externo)           : $( pgrep -x xray &>/dev/null && echo -e "${C_GREEN}ACTIVO (Intacto)${C_RESET}" || echo -e "${C_GRAY}No detectado${C_RESET}" )"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

informacion_ficha_vps() {
    mostrar_pantalla_encabezado
    local os_name kern cpu_mod cores up_txt bbr_st ip_pub
    os_name=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -s)
    kern=$(uname -r)
    cpu_mod=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)
    [ -z "$cpu_mod" ] && cpu_mod=$(lscpu 2>/dev/null | grep "Model name:" | cut -d: -f2 | xargs || uname -m)
    cores=$(nproc 2>/dev/null || echo 1)
    up_txt=$(uptime -p 2>/dev/null || uptime)
    bbr_st=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubic")
    ip_pub=$(obtener_ip)

    echo -e "${C_NEON}┌──────────── FICHA TÉCNICA DEL SERVIDOR VPS ──────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Dirección IPv4   :${C_RESET} ${C_WHITE}$ip_pub${C_RESET}"
    echo -e "  ${C_CYAN}Sistema Operativo:${C_RESET} ${C_WHITE}$os_name${C_RESET}"
    echo -e "  ${C_CYAN}Versión Kernel   :${C_RESET} ${C_WHITE}$kern ($(uname -m))${C_RESET}"
    echo -e "  ${C_CYAN}Procesador (CPU) :${C_RESET} ${C_WHITE}$cpu_mod ($cores núcleos)${C_RESET}"
    echo -e "  ${C_CYAN}Tiempo Encendido :${C_RESET} ${C_GREEN}$up_txt${C_RESET}"
    echo -e "  ${C_CYAN}Control TCP      :${C_RESET} ${C_YELLOW}$bbr_st${C_RESET}"
    echo -e "  ${C_CYAN}Versión Panel    :${C_RESET} ${C_NEON}BLUE COMPANY ${EDICION_SCRIPT}${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    read -r -p "  Presiona Enter para volver..."
}

# ==============================================================================
# CATEGORÍA 4: HERRAMIENTAS, BACKUPS, REPARACIÓN Y ACTUALIZACIÓN GITHUB
# ==============================================================================

# Crea copia de seguridad con fecha y tipo sin sobrescribir copias previas
crear_respaldo_sistema() {
    local tipo="${1:-manual}"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    local stamp archivo_destino
    stamp=$(date "+%Y%m%d-%H%M%S")
    archivo_destino="${BACKUP_DIR}/backup-blue-${stamp}-${tipo}.tar.gz"
    if [ -f "$archivo_destino" ]; then
        archivo_destino="${BACKUP_DIR}/backup-blue-${stamp}-${RANDOM}-${tipo}.tar.gz"
    fi

    # Empaquetar base de datos de usuarios, configuraciones de bluecompany y binario actual
    # NUNCA incluye claves privadas SSH del host (/etc/ssh/ssh_host_* ni /root/.ssh)
    if ! tar -czf "$archivo_destino" \
        "$DB_LIMITS" \
        "$CONF_DIR" \
        "$BIN_TARGET" 2>/dev/null || ! tar -tzf "$archivo_destino" >/dev/null 2>&1; then
        rm -f "$archivo_destino"
        echo "ERROR: no se pudo crear/verificar el respaldo" >&2
        return 1
    fi

    chmod 600 "$archivo_destino" 2>/dev/null
    # No se escribe una copia espejo con nombre fijo: evita sobrescribir respaldos previos.
    registrar_accion_admin "CREAR_BACKUP" "Tipo=${tipo} Archivo=$(basename "$archivo_destino")"
    echo "$archivo_destino"
}

menu_copias_seguridad() {
    mostrar_pantalla_encabezado
    echo -e "${C_NEON}┌───────── GESTIÓN DE COPIAS DE SEGURIDAD ─────────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Respaldos almacenados en ${BACKUP_DIR}:${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"

    local count=0
    if compgen -G "${BACKUP_DIR}/backup-blue-*.tar.gz" > /dev/null; then
        printf "${C_BOLD}${C_CYAN} %-4s %-34s %-10s %-16s${C_RESET}\n" "N°" "ARCHIVO" "TAMAÑO" "FECHA"
        while IFS= read -r f; do
            count=$(( count + 1 ))
            local sz dt bn
            bn=$(basename "$f")
            sz=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            dt=$(date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null)
            printf " ${C_YELLOW}[%02d]${C_RESET} %-34.34s ${C_GREEN}%-10s${C_RESET} %-16s\n" "$count" "$bn" "$sz" "$dt"
        done < <(ls -1t "${BACKUP_DIR}"/backup-blue-*.tar.gz 2>/dev/null | head -n 15)
    else
        echo -e "  ${C_YELLOW}No hay respaldos históricos en ${BACKUP_DIR}.${C_RESET}"
    fi

    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Crear Nueva Copia de Seguridad Manual Ahora"
    echo -e "  ${C_WHITE}[2]${C_RESET} Ir a Restauración de Respaldos"
    echo -e "  ${C_GRAY}[0] Volver${C_RESET}"
    read -r -p "  ► Opción: " op_b

    case "$op_b" in
        1)
            local nuevo_bk sz_bk
            nuevo_bk=$(crear_respaldo_sistema "manual")
            sz_bk=$(du -h "$nuevo_bk" 2>/dev/null | awk '{print $1}')
            echo -e "\n  ${C_GREEN}[✓] Copia de seguridad creada exitosamente:${C_RESET}"
            echo -e "  ${C_WHITE}Archivo:${C_RESET} $nuevo_bk ($sz_bk)"
            read -r -p "  Presiona Enter para volver..."
            ;;
        2) menu_restaurar_respaldo ;;
        *) return ;;
    esac
}

menu_restaurar_respaldo() {
    echo -e "  ${C_YELLOW}[!] La restauración queda bloqueada hasta implementar validación criptográfica y simulación previa. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

actualizar_desde_github() {
    echo -e "  ${C_YELLOW}[!] La actualización remota queda bloqueada: el repositorio no ofrece firma/checksum verificado en este flujo. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

reparacion_inteligente_vps() {
    echo -e "  ${C_YELLOW}[!] La reparación automática queda bloqueada para proteger servicios, puertos y reglas de red existentes. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

instalar_dropbear_auto() {
    echo -e "  ${C_YELLOW}[!] No se instala ni reinicia Dropbear desde el panel protegido. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

instalar_despachador_auto() {
    echo -e "  ${C_YELLOW}[!] No se modifica el despachador ni sus puertos desde el panel protegido. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

instalar_limitador_auto() {
    echo -e "  ${C_YELLOW}[!] No se crean ni reinician servicios systemd desde el panel protegido. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

instalar_badvpn_auto() {
    echo -e "  ${C_YELLOW}[!] No se instala ni reinicia BadVPN desde el panel protegido. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

optimizar_tcp_sin_retraso() {
    echo -e "  ${C_YELLOW}[!] No se aplican cambios de sysctl, interfaces de red ni configuración SSH. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

instalacion_completa_vps() {
    echo -e "  ${C_YELLOW}[!] El despliegue masivo está deshabilitado para evitar cambios sobre un VPS ya configurado. El servidor permanece sin cambios.${C_RESET}"
    return 1
}

informacion_version_y_modulos() {
    mostrar_pantalla_encabezado
    local v_rem
    v_rem=$(verificar_actualizacion_cache)
    echo -e "${C_NEON}┌────── INFORMACIÓN DE VERSIÓN Y MÓDULOS BASE ─────────┐${C_RESET}"
    echo -e "  ${C_CYAN}Nombre del Sistema:${C_RESET} ${C_WHITE}BLUE COMPANY • CLOUD NETWORK MANAGER${C_RESET}"
    echo -e "  ${C_CYAN}Edición Instalada :${C_RESET} ${C_GREEN}${EDICION_SCRIPT}${C_RESET}"
    echo -e "  ${C_CYAN}Versión en GitHub :${C_RESET} ${C_YELLOW}v${v_rem}${C_RESET}"
    echo -e "  ${C_CYAN}Repositorio       :${C_RESET} ${C_GRAY}${GITHUB_REPO_URL}${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_CYAN}Instaladores Individuales de Infraestructura:${C_RESET}"
    echo -e "  ${C_WHITE}[1]${C_RESET} Instalar / Reconfigurar Dropbear (Puerto 2222)"
    echo -e "  ${C_WHITE}[2]${C_RESET} Instalar / Reconfigurar Despachador WS (P:80/8080/8880)"
    echo -e "  ${C_WHITE}[3]${C_RESET} Instalar / Reconfigurar BadVPN UDPGW (Puerto 7300)"
    echo -e "  ${C_WHITE}[4]${C_RESET} Aplicar Perfil Kernel TCP BBR + LowLatency"
    echo -e "  ${C_WHITE}[5]${C_RESET} Despliegue Completo 1-Click (Para VPS recién instalada)"
    echo -e "  ${C_GRAY}[0] Volver al menú principal${C_RESET}"
    read -r -p "  ► Opción: " op_iv

    case "$op_iv" in
        1) instalar_dropbear_auto ;;
        2) instalar_despachador_auto ;;
        3) instalar_badvpn_auto ;;
        4) optimizar_tcp_sin_retraso ;;
        5) instalacion_completa_vps ;;
        *) return ;;
    esac
}

# ==============================================================================
# MENÚ PRINCIPAL ORGANIZADO EN 4 CATEGORÍAS CORPORATIVAS (ENTERPRISE v9.0)
# ==============================================================================

while true; do
    mostrar_pantalla_encabezado
    echo -e "  ${C_CYAN}━━ 1. GESTIÓN COMERCIAL ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[01]${C_RESET} ${C_WHITE}Crear usuarios (Cliente o Demo 1-Click)${C_RESET}"
    echo -e "  ${C_NEON}[02]${C_RESET} ${C_WHITE}Modificar usuarios (Contraseña, Límite o Renovar)${C_RESET}"
    echo -e "  ${C_NEON}[03]${C_RESET} ${C_WHITE}Eliminar usuarios (Individual o Purgar vencidos)${C_RESET}"
    echo -e "  ${C_NEON}[04]${C_RESET} ${C_WHITE}Bloquear y desbloquear (Suspender / Reintegrar)${C_RESET}"
    echo -e "  ${C_NEON}[05]${C_RESET} ${C_WHITE}Consultar vencimientos y Ficha / Ticket${C_RESET}"
    echo -e "  ${C_NEON}[06]${C_RESET} ${C_WHITE}Consultar límites de conexiones${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}━━ 2. MONITOREO Y SEGURIDAD ━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[07]${C_RESET} ${C_GREEN}Usuarios conectados (Monitor en Tiempo Real)${C_RESET}"
    echo -e "  ${C_NEON}[08]${C_RESET} ${C_WHITE}Monitor de consumo por usuario${C_RESET}"
    echo -e "  ${C_NEON}[09]${C_RESET} ${C_WHITE}Bloqueos automáticos (Auto-Limitador y Reintegro)${C_RESET}"
    echo -e "  ${C_NEON}[10]${C_RESET} ${C_WHITE}Historial (Bloqueos, motivos y auditoría)${C_RESET}"
    echo -e "  ${C_NEON}[11]${C_RESET} ${C_WHITE}Seguridad (Anti-BruteForce, IPs y Anti-Torrent)${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}━━ 3. INFRAESTRUCTURA ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[12]${C_RESET} ${C_WHITE}Estado de servicios (BLUE COMPANY vs Externos)${C_RESET}"
    echo -e "  ${C_NEON}[13]${C_RESET} ${C_WHITE}Puertos en escucha y redirecciones NAT${C_RESET}"
    echo -e "  ${C_NEON}[14]${C_RESET} ${C_WHITE}CPU, RAM, Carga y Procesos activos${C_RESET}"
    echo -e "  ${C_NEON}[15]${C_RESET} ${C_WHITE}Diagnóstico del VPS (Disco, Red y Salud)${C_RESET}"
    echo -e "  ${C_NEON}[16]${C_RESET} ${C_WHITE}Información técnica del VPS${C_RESET}"
    echo -e ""
    echo -e "  ${C_CYAN}━━ 4. HERRAMIENTAS Y MANTENIMIENTO ━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "  ${C_NEON}[17]${C_RESET} ${C_YELLOW}Actualización desde GitHub (Con Backup y Rollback)${C_RESET}"
    echo -e "  ${C_NEON}[18]${C_RESET} ${C_WHITE}Copias de seguridad (Manuales e Históricas)${C_RESET}"
    echo -e "  ${C_NEON}[19]${C_RESET} ${C_WHITE}Restauración de respaldos${C_RESET}"
    echo -e "  ${C_NEON}[20]${C_RESET} ${C_WHITE}Reparación inteligente (Sin corte de túneles)${C_RESET}"
    echo -e "  ${C_NEON}[21]${C_RESET} ${C_WHITE}Información de versión y Módulos base${C_RESET}"
    echo -e "${C_BLUE}────────────────────────────────────────────────────────${C_RESET}"
    echo -e "  ${C_RED}[00]${C_RESET} ${C_GRAY}Salir del Panel${C_RESET}"
    echo -e "${C_BLUE}════════════════════════════════════════════════════════${C_RESET}"
    read -r -p "  ► Selecciona una opción [0-21]: " opcion

    case "$opcion" in
        1|01) crear_usuario ;;
        2|02) modificar_usuario ;;
        3|03) eliminar_usuario ;;
        4|04) controlar_acceso_usuario ;;
        5|05) consultar_vencimientos ;;
        6|06) consultar_limites_clientes ;;
        7|07) listar_usuarios_en_vivo ;;
        8|08) monitor_consumo_usuarios ;;
        9|09) gestion_bloqueos_automaticos ;;
        10)   consultar_historial_sistema ;;
        11)   centro_seguridad_vps ;;
        12)   estado_servicios_diferenciado ;;
        13)   puertos_en_escucha_vps ;;
        14)   monitor_cpu_ram_procesos ;;
        15)   diagnostico_integral_vps ;;
        16)   informacion_ficha_vps ;;
        17)   actualizar_desde_github ;;
        18)   menu_copias_seguridad ;;
        19)   menu_restaurar_respaldo ;;
        20)   reparacion_inteligente_vps ;;
        21)   informacion_version_y_modulos ;;
        0|00)
            flock -u 9 2>/dev/null
            clear
            exit 0
            ;;
        *)
            echo -e "\n  ${C_RED}[!] Opción no válida.${C_RESET}"
            sleep 1
            ;;
    esac
done
