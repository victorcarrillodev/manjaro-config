#!/usr/bin/env bash
#
# config.sh
# Configurador de un Manjaro instalado en una memoria USB (flash): sirve
# para CUALQUIER USB al que le instales Manjaro, no solo el actual. Primero
# aplica optimizaciones de rendimiento propias de un sistema que vive en
# flash USB, y después instala un entorno de desarrollo completo (AUR
# helper, lenguajes/runtimes, editores, herramientas de IA, WhatsApp y
# navegadores). Es idempotente mientras corre (cada paso detecta lo que ya
# está hecho y solo aplica lo que falta) y AL TERMINAR SIN ERRORES se limpia
# solo: borra archivos residuales de la instalación (caché de build de yay,
# caché de pacman, dependencias huérfanas) y se autoelimina.
#
# Uso:
#   ./config.sh                  # corre todo el proceso (pasos A-I)
#   ./config.sh --only-optimize  # solo el paso A (rendimiento), no
#                                 # instala nada y NO se autoelimina
#   ./config.sh -h | --help
#
# IMPORTANTE:
#   - No lo corras con sudo directamente: yay no puede compilar paquetes AUR
#     como root, así que el script pide privilegios internamente solo para
#     lo que sí los requiere (pacman, systemctl, /etc).
#   - Si terminó TODO el proceso sin errores, el script se borra a sí mismo
#     al final. Si vas a necesitarlo de nuevo (otro USB, otra reinstalación),
#     guardate una copia aparte antes de correrlo.
#
# Nota de seguridad: a mediados de 2026 hubo (y sigue habiendo) una campaña
# de paquetes AUR adoptados y comprometidos con malware. Por eso los pasos
# que instalan paquetes AUR NO usan --noconfirm: yay te va a mostrar el
# PKGBUILD/diff de cada paquete antes de compilarlo. Date el tiempo de
# revisarlo, sobre todo en paquetes que no reconozcas.

set -uo pipefail

SCRIPT_PATH="$(readlink -f "$0")"
ACTION="${1:-}"

# ===========================================================================
# Salida y control de errores
# ===========================================================================
log()  { echo -e "\e[1;32m[manjaro-setup]\e[0m $*"; }
warn() { echo -e "\e[1;33m[manjaro-setup]\e[0m $*"; }
err()  { echo -e "\e[1;31m[manjaro-setup]\e[0m $*" >&2; }

FAILURES=0
fail() { warn "$*"; FAILURES=$((FAILURES + 1)); }

print_banner() {
    echo -e "\e[1;35m"
    cat <<'BANNER'
========================================================================
  MANJARO USB SETUP - configurador de entorno de desarrollo
  rendimiento -> yay -> lenguajes -> editores -> IA -> navegadores
  (se autolimpia y se autoelimina al terminar sin errores)
========================================================================
BANNER
    echo -e "\e[0m"
}

print_help() {
    cat <<USAGE
Uso:
  $0                       corre todo el proceso (pasos A-I) y, si termina
                           sin errores, limpia residuales y se autoelimina
  $0 --only-optimize       aplica solo el paso A (rendimiento) y sale;
                           no instala nada y NO se autoelimina
  $0 -h | --help           esta ayuda

No lo corras con sudo directamente: el script pide privilegios cuando los
necesita.
USAGE
}

case "$ACTION" in
    ""|--only-optimize)
        ;;
    -h|--help)
        print_help
        exit 0
        ;;
    *)
        err "Opción desconocida: $ACTION"
        print_help >&2
        exit 1
        ;;
esac

if [[ $EUID -eq 0 ]]; then
    err "No ejecutes este script como root/sudo directamente."
    err "yay no puede compilar paquetes AUR corriendo como root."
    err "Corrélo como tu usuario normal: ./$(basename "$SCRIPT_PATH")"
    exit 1
fi

# ---------------------------------------------------------------------------
# Letras de paso: dejan clarísimo en qué punto del proceso está corriendo.
# ---------------------------------------------------------------------------
LETTERS=(A B C D E F G H I J)
STEP_INDEX=0
step() {
    echo -e "\n\e[1;36m[${LETTERS[$STEP_INDEX]}]\e[0m \e[1m$*\e[0m"
    STEP_INDEX=$((STEP_INDEX + 1))
}

request_sudo() {
    log "Vas a necesitar tu contraseña de sudo para varios pasos (pacman, systemd)."
    sudo -v || { err "No se pudo obtener sudo."; exit 1; }
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
    trap 'kill "$!" 2>/dev/null' EXIT
}

# ===========================================================================
# Paso A: optimización de rendimiento del sistema en el USB.
# Pide sudo puntualmente en cada comando que lo necesita.
# ===========================================================================
optimize_system_performance() {
    # -----------------------------------------------------------------
    # 1. Detectar el disco raíz (sin importar si es sda, sdb, etc.)
    #    Sigue la cadena de dispositivos (LUKS/LVM/device-mapper) hasta
    #    llegar al disco físico real, no solo un nivel de padre.
    # -----------------------------------------------------------------
    local root_src root_fstype root_disk root_disk_path root_bus
    root_src=$(findmnt -no SOURCE /)
    root_fstype=$(findmnt -no FSTYPE /)

    local dev parent
    dev="$root_src"
    while parent=$(lsblk -ndo PKNAME "$dev" 2>/dev/null) && [[ -n "$parent" ]]; do
        dev="/dev/${parent}"
    done
    root_disk=$(basename "$dev")
    root_disk_path="/dev/${root_disk}"
    root_bus=$(udevadm info --query=property --name="$root_disk_path" 2>/dev/null | grep -oP '(?<=ID_BUS=).*')

    log "Dispositivo raíz: $root_src ($root_fstype) sobre $root_disk_path (bus: ${root_bus:-desconocido})"

    if [[ "$root_bus" != "usb" ]]; then
        warn "El disco raíz no se detecta como USB (bus=$root_bus). Se aplican igual los ajustes,"
        warn "pero revisá que sea correcto si esto no corre desde la memoria USB."
    fi

    # -----------------------------------------------------------------
    # 2. fstab: noatime + commit más espaciado para reducir escrituras
    # -----------------------------------------------------------------
    local fstab=/etc/fstab
    if [[ -f "$fstab" ]]; then
        if ! grep -qP '^\s*[^#].*\s/\s' "$fstab"; then
            warn "No se encontró línea de '/' en fstab, se omite este paso."
        else
            sudo cp -n "$fstab" "${fstab}.bak-optimizar-usb" 2>/dev/null || true
            # "commit=" solo existe en ext2/3/4, btrfs y f2fs; en XFS, vfat,
            # etc. no es una opción válida y podría romper el montaje.
            awk -v OFS='\t' -v fstype="$root_fstype" '
                $1 !~ /^#/ && $2 == "/" {
                    opts = $4
                    if (opts !~ /noatime/) {
                        gsub(/relatime/, "noatime", opts)
                        if (opts !~ /noatime/) opts = opts ",noatime"
                    }
                    supports_commit = (fstype == "ext2" || fstype == "ext3" || fstype == "ext4" || fstype == "btrfs" || fstype == "f2fs")
                    if (opts !~ /commit=/ && supports_commit) opts = opts ",commit=60"
                    $4 = opts
                }
                { print }
            ' "$fstab" | sudo tee "${fstab}.tmp" >/dev/null && sudo mv "${fstab}.tmp" "$fstab"
            log "fstab actualizado (respaldo en ${fstab}.bak-optimizar-usb si no existía ya)."
        fi
    else
        warn "No existe /etc/fstab, se omite este paso."
    fi

    sudo mount -o remount / 2>/dev/null && log "Remount de / aplicado." || warn "No se pudo remontar / en caliente (se aplicará en el próximo arranque)."

    # -----------------------------------------------------------------
    # 3. sysctl: dirty ratios más bajos, swappiness alto (swap es zram)
    # -----------------------------------------------------------------
    sudo tee /etc/sysctl.d/99-usb-performance.conf >/dev/null <<'EOF'
# Generado por config.sh — ajustes para sistema instalado en USB

# Escrituras más pequeñas y frecuentes en vez de ráfagas grandes que
# congelan la interfaz mientras el USB (lento) las procesa.
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10

# Con zram como swap (vive en RAM comprimida), conviene usarlo de forma
# agresiva antes que desalojar caché de página, ya que no desgasta el USB.
vm.swappiness = 100

# Menos presión sobre el caché de inodos/dentries: en un USB lento, releer
# metadatos del disco es caro, así que preferimos mantenerlos en RAM.
vm.vfs_cache_pressure = 50
EOF
    sudo sysctl --system >/dev/null 2>&1
    log "Parámetros vm.* aplicados (dirty ratios, swappiness, vfs_cache_pressure)."

    # -----------------------------------------------------------------
    # 4. udev: scheduler y read-ahead para CUALQUIER disco USB conectado
    # -----------------------------------------------------------------
    sudo tee /etc/udev/rules.d/60-usb-storage-performance.rules >/dev/null <<'EOF'
# Generado por config.sh — aplica a cualquier disco USB conectado
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_BUS}=="usb", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_BUS}=="usb", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_BUS}=="usb", ATTR{queue/nr_requests}="128"
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_BUS}=="usb", ATTR{queue/add_random}="0"
EOF
    sudo udevadm control --reload-rules 2>/dev/null
    sudo udevadm trigger --subsystem-match=block 2>/dev/null

    if [[ -n "$root_disk" ]] && [[ -w "/sys/block/${root_disk}/queue/scheduler" ]]; then
        echo mq-deadline | sudo tee "/sys/block/${root_disk}/queue/scheduler" >/dev/null 2>&1 || true
        echo 1024 | sudo tee "/sys/block/${root_disk}/queue/read_ahead_kb" >/dev/null 2>&1 || true
        echo 128 | sudo tee "/sys/block/${root_disk}/queue/nr_requests" >/dev/null 2>&1 || true
    fi
    log "Regla udev instalada y aplicada (scheduler mq-deadline, read-ahead 1024KB) para discos USB."

    # -----------------------------------------------------------------
    # 5. journald: limitar tamaño para no llenar el USB con logs
    # -----------------------------------------------------------------
    sudo mkdir -p /etc/systemd/journald.conf.d
    sudo tee /etc/systemd/journald.conf.d/00-usb-size.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=100M
EOF
    sudo systemctl restart systemd-journald 2>/dev/null
    log "Journal limitado a 100M."

    # -----------------------------------------------------------------
    # 6. TRIM periódico (mejor que discard continuo para flash USB)
    # -----------------------------------------------------------------
    sudo systemctl enable --now fstrim.timer >/dev/null 2>&1
    log "fstrim.timer activo (TRIM semanal)."

    # -----------------------------------------------------------------
    # 7. Arranque más rápido: no esperar a que la red "termine" de conectar
    # -----------------------------------------------------------------
    if systemctl is-enabled NetworkManager-wait-online.service >/dev/null 2>&1; then
        sudo systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1
        log "NetworkManager-wait-online deshabilitado (arranque más rápido)."
    fi

    # -----------------------------------------------------------------
    # 8. zram: swap comprimido en RAM en vez de swap en el USB (no
    #    desgasta la flash y es mucho más rápido que un swapfile en USB)
    # -----------------------------------------------------------------
    pacman -Qi zram-generator &>/dev/null || sudo pacman -S --needed --noconfirm zram-generator
    sudo mkdir -p /etc/systemd/zram-generator.conf.d
    sudo tee /etc/systemd/zram-generator.conf.d/00-usb.conf >/dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOF
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true
    log "zram configurado como swap (mitad de la RAM, compresión zstd)."

    # -----------------------------------------------------------------
    # 9. cpupower: governor "performance" (prioriza velocidad sobre
    #    ahorro de energía, coherente con el resto de estos ajustes)
    # -----------------------------------------------------------------
    pacman -Qi cpupower &>/dev/null || sudo pacman -S --needed --noconfirm cpupower
    if [[ -f /etc/default/cpupower ]]; then
        if grep -q '^governor=' /etc/default/cpupower; then
            sudo sed -i "s/^governor=.*/governor='performance'/" /etc/default/cpupower
        else
            echo "governor='performance'" | sudo tee -a /etc/default/cpupower >/dev/null
        fi
    fi
    sudo systemctl enable --now cpupower.service 2>/dev/null
    log "cpupower configurado con governor 'performance'."

    log "Optimización de rendimiento completa."
}

# ===========================================================================
# Helpers de instalación (idempotentes, van sumando a FAILURES si fallan)
# ===========================================================================
install_pkg() { # paquete de repo oficial (pacman)
    local pkg="$1"
    if pacman -Qi "$pkg" &>/dev/null; then
        log "  · $pkg ya está instalado."
        return 0
    fi
    log "  · Instalando $pkg (repo oficial)..."
    if sudo pacman -S --needed --noconfirm "$pkg"; then
        return 0
    fi
    fail "  No se pudo instalar $pkg."
    return 1
}

install_aur() { # paquete AUR vía yay — SIN --noconfirm: yay muestra el PKGBUILD/diff
    local pkg="$1"
    if yay -Qi "$pkg" &>/dev/null; then
        log "  · $pkg ya está instalado (AUR)."
        return 0
    fi
    log "  · Instalando $pkg (AUR)... revisá el PKGBUILD/diff que muestre yay."
    if yay -S --needed "$pkg"; then
        return 0
    fi
    fail "  No se pudo instalar $pkg desde AUR."
    return 1
}

install_yay() {
    if command -v yay &>/dev/null; then
        log "  · yay ya está instalado."
        return 0
    fi
    log "  · Compilando e instalando yay (yay-bin)..."
    sudo pacman -S --needed --noconfirm git base-devel
    local tmp
    tmp=$(mktemp -d /tmp/manjaro-setup.XXXXXX)
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin"
    (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
    command -v yay &>/dev/null || fail "  yay no quedó instalado; los pasos de AUR van a fallar."
}

install_dev_tools() {
    install_pkg git
    install_pkg nodejs
    install_pkg npm

    if command -v pnpm &>/dev/null; then
        log "  · pnpm ya está instalado."
    else
        log "  · Instalando pnpm..."
        curl -fsSL https://get.pnpm.io/install.sh | sh -
        command -v "$HOME/.local/share/pnpm/pnpm" &>/dev/null || fail "  pnpm no quedó instalado."
    fi

    if command -v bun &>/dev/null; then
        log "  · bun ya está instalado."
    else
        log "  · Instalando bun..."
        curl -fsSL https://bun.sh/install | bash
        command -v "$HOME/.bun/bin/bun" &>/dev/null || fail "  bun no quedó instalado."
    fi

    if install_pkg docker; then
        sudo systemctl enable --now docker.service || fail "  No se pudo habilitar el servicio docker."
        if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
            sudo usermod -aG docker "$USER"
            warn "  Te agregué al grupo docker. Cerrá sesión (o reiniciá) para poder usar 'docker' sin sudo."
        fi

        # Docker es, de lejos, el que más escribe al disco (capas de imágenes,
        # logs de contenedores). Topamos los logs y podamos semanalmente lo
        # que ya no se usa, para no acumular basura en la USB sin límite.
        if [[ ! -f /etc/docker/daemon.json ]]; then
            sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
            sudo systemctl restart docker.service
            log "  · Logs de contenedores acotados a 10MB x 3 archivos por contenedor."
        else
            log "  · /etc/docker/daemon.json ya existe, no lo toco."
        fi

        sudo tee /etc/systemd/system/docker-prune.service >/dev/null <<'EOF'
[Unit]
Description=Limpieza semanal de recursos de Docker sin usar
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -f
EOF
        sudo tee /etc/systemd/system/docker-prune.timer >/dev/null <<'EOF'
[Unit]
Description=Corre docker-prune.service semanalmente

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now docker-prune.timer
        log "  · docker-prune.timer activo (poda semanal de imágenes/contenedores sin usar)."
    fi

    install_aur flutter-bin

    if command -v rustup &>/dev/null; then
        log "  · rustup ya está instalado."
    else
        log "  · Instalando Rust vía rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        command -v "$HOME/.cargo/bin/rustup" &>/dev/null || fail "  rustup no quedó instalado."
    fi

    # Si /tmp es tmpfs (RAM) — el default en este Manjaro — mandamos ahí los
    # artefactos de compilación de cargo: son descartables, se regeneran solos
    # y así ni pesan ni desgastan la USB, y compilan bastante más rápido.
    if [[ "$(findmnt -no FSTYPE /tmp 2>/dev/null)" == "tmpfs" ]]; then
        local cargo_config="$HOME/.cargo/config.toml"
        mkdir -p "$HOME/.cargo"
        if [[ -f "$cargo_config" ]] && grep -q 'target-dir' "$cargo_config" 2>/dev/null; then
            log "  · target-dir de cargo ya está configurado."
        elif [[ -f "$cargo_config" ]] && grep -q '^\[build\]' "$cargo_config" 2>/dev/null; then
            warn "  ~/.cargo/config.toml ya tiene una sección [build]; no la toco."
            warn "  Agregale 'target-dir = \"/tmp/cargo-target\"' a mano si querés compilar en RAM."
        else
            cat >> "$cargo_config" <<'EOF'

[build]
# /tmp es tmpfs (RAM) en este sistema: compilar ahí es más rápido y no
# desgasta la USB. Se pierde el caché incremental al reiniciar, no pasa nada.
target-dir = "/tmp/cargo-target"
EOF
            log "  · cargo va a compilar en /tmp (RAM) en vez de en la USB."
        fi
    fi
}

install_editors() {
    install_aur cursor-bin

    if command -v antigravity &>/dev/null; then
        log "  · Antigravity IDE ya está instalado."
    else
        install_aur antigravity-ide
        if ! command -v antigravity &>/dev/null; then
            warn "  Antigravity IDE no quedó instalado desde AUR."
            warn "  Bajalo a mano desde https://antigravity.google/download/linux"
        fi
    fi
}

install_ai_tools() {
    if command -v claude &>/dev/null; then
        log "  · Claude Code CLI ya está instalado."
    else
        log "  · Instalando Claude Code CLI..."
        curl -fsSL https://claude.ai/install.sh | bash
        command -v claude &>/dev/null || fail "  Claude Code CLI no quedó instalado."
    fi

    install_aur claude-desktop
    warn "  claude-desktop es un paquete AUR no oficial (Anthropic solo da soporte oficial de escritorio para Debian/Ubuntu)."

    if command -v agy &>/dev/null; then
        log "  · Antigravity CLI ya está instalado."
    else
        log "  · Instalando Antigravity CLI..."
        curl -fsSL https://antigravity.google/cli/install.sh | bash
        command -v agy &>/dev/null || fail "  Antigravity CLI no quedó instalado."
    fi

    if command -v opencode &>/dev/null; then
        log "  · opencode ya está instalado."
    else
        log "  · Instalando opencode..."
        curl -fsSL https://opencode.ai/install | bash
        command -v opencode &>/dev/null || fail "  opencode no quedó instalado."
    fi
}

install_browsers() {
    install_aur brave-nightly-bin
    install_aur google-chrome

    if pacman -Qi firefox &>/dev/null; then
        log "  · Desinstalando Firefox..."
        sudo pacman -Rns --noconfirm firefox || warn "  No se pudo desinstalar Firefox (revisá si algo más depende de él)."
    else
        log "  · Firefox no está instalado, nada que quitar."
    fi
}

# ===========================================================================
# Limpieza final y autoeliminación
# ===========================================================================
cleanup_residuals() {
    log "  · Limpiando caché de compilación de yay (~/.cache/yay)..."
    rm -rf "$HOME/.cache/yay"

    log "  · Limpiando caché de paquetes de pacman ya no instalados..."
    sudo pacman -Sc --noconfirm >/dev/null

    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        log "  · Quitando dependencias huérfanas: $(echo "$orphans" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        sudo pacman -Rns --noconfirm $orphans || warn "  No se pudieron quitar todas las dependencias huérfanas."
    else
        log "  · No hay dependencias huérfanas."
    fi

    rm -rf /tmp/manjaro-setup.*
    log "Limpieza de residuales completa."
}

print_summary() {
    log "Proceso terminado."
    cat <<'SUMMARY'

Pendientes que necesitan una acción tuya:
  · Docker: si te acaba de agregar al grupo docker, cerrá sesión y volvé a
    entrar (o reiniciá) antes de usar 'docker' sin sudo.
  · Rust, pnpm y bun: abrí una terminal nueva (sus instaladores agregan el
    PATH al perfil de shell) para que 'cargo'/'rustc', 'pnpm' y 'bun'
    aparezcan disponibles.
  · Antigravity IDE/CLI, Claude Code (CLI/desktop) y opencode piden iniciar
    sesión con tu cuenta la primera vez que los abras.
  · Hay una campaña activa de paquetes AUR comprometidos (2026): si no
    llegaste a revisar algún PKGBUILD que yay te mostró, dale una repasada
    antes de confiar ciegamente en el resultado.
SUMMARY
}

self_destruct() {
    if [[ "$FAILURES" -gt 0 ]]; then
        warn "Hubo $FAILURES paso(s) con errores: NO me autoelimino para que puedas revisar y volver a correrme."
        return
    fi
    log "Todo terminó sin errores. Autoeliminando $SCRIPT_PATH..."
    rm -f -- "$SCRIPT_PATH"
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    print_banner
    request_sudo

    if [[ "$ACTION" == "--only-optimize" ]]; then
        step "Optimización de rendimiento del sistema (USB)"
        optimize_system_performance
        exit 0
    fi

    step "Optimización de rendimiento del sistema (USB)"
    optimize_system_performance

    step "Actualización del sistema e instalación de yay (AUR helper)"
    sudo pacman -Syu --noconfirm
    install_yay

    step "Herramientas de desarrollo: git, Node.js, pnpm, bun, Docker, Flutter, Rust"
    install_dev_tools

    step "Editores e IDEs: Cursor, Antigravity IDE"
    install_editors

    step "Herramientas de IA: Claude Code CLI/Desktop, Antigravity CLI, opencode"
    install_ai_tools

    step "WhatsApp Desktop (ZapZap)"
    install_aur zapzap

    step "Navegadores: Brave Nightly + Google Chrome (fuera Firefox)"
    install_browsers

    step "Limpieza de archivos residuales"
    cleanup_residuals

    step "Resumen y autoeliminación"
    print_summary
    self_destruct
}

main
