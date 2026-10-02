#!/bin/bash

# ===========================================================================
# Variables Globales y Colores
# ===========================================================================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
INSTALL_MODE=""
FAILED=()

# Archivos que crea el modo USB (se eliminan al elegir modo Escritorio)
USB_SYSCTL_CONF="/etc/sysctl.d/99-usb-optimize.conf"
USB_JOURNALD_CONF="/etc/systemd/journald.conf.d/99-usb-optimize.conf"
USB_UDEV_RULE="/etc/udev/rules.d/60-usb-ioscheduler.rules"
USB_ZRAM_CONF="/etc/systemd/zram-generator.conf"

# Opciones para que yay no se detenga en menús interactivos
YAY_OPTS=(--needed --noconfirm --answerdiff None --answerclean None --removemake --sudoloop)

# ===========================================================================
# Prevención de ejecución como Root (CRÍTICO PARA YAY/AUR)
# ===========================================================================
if [ "$EUID" -eq 0 ]; then
  echo -e "${RED}ERROR: Por favor, NO ejecutes este script como root ni uses 'sudo ./config.sh'.${NC}"
  echo -e "Ejecútalo como tu usuario normal (ej. ${CYAN}bash config.sh${NC})."
  echo "Yay fallará si se ejecuta como root."
  exit 1
fi

# ===========================================================================
# Funciones Auxiliares
# ===========================================================================
print_banner() {
    echo -e "${CYAN}=== Script de Instalación y Configuración (Manjaro Edition) ===${NC}"
}

request_sudo() {
    echo -e "${YELLOW}Solicitando permisos de administrador para la instalación...${NC}"
    sudo -v || { echo -e "${RED}No se obtuvieron permisos de sudo.${NC}"; exit 1; }
    # Mantener el sudo vivo mientras el script se ejecuta
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
}

step() {
    echo -e "\n${GREEN}[*] $1${NC}"
}

skip_msg() {
    echo -e "${YELLOW} -> Ya instalado, omitiendo...${NC}"
}

fail() {
    echo -e "${RED} -> ERROR instalando $1${NC}"
    FAILED+=("$1")
}

yay_install() {
    if ! command -v yay &> /dev/null; then
        echo -e "${RED} -> yay no está disponible${NC}"
        return 1
    fi
    yay -S "${YAY_OPTS[@]}" "$@"
}

# ensure <nombre> <comando|""> <pacman|aur> <paquete>...
# Si se indica un comando se usa para detectar si ya está instalado;
# si no, se comprueba el primer paquete con pacman -Q.
ensure() {
    local label=$1 check=$2 source=$3
    shift 3

    echo -n "$label: "
    if [[ -n "$check" ]] && command -v "$check" &> /dev/null; then skip_msg; return 0; fi
    if [[ -z "$check" ]] && pacman -Q "$1" &> /dev/null; then skip_msg; return 0; fi
    echo "instalando..."

    if [[ "$source" == "pacman" ]]; then
        sudo pacman -S --needed --noconfirm "$@" || { fail "$label"; return 1; }
    else
        yay_install "$@" || { fail "$label"; return 1; }
    fi
    echo -e "${GREEN} -> $label instalado${NC}"
}

# Añade una línea a los archivos de configuración del shell si no existe ya
add_to_shell_rc() {
    local line=$1 rc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
        [[ -f "$rc" ]] || continue
        grep -qxF "$line" "$rc" || echo "$line" >> "$rc"
    done
}

# ===========================================================================
# Optimizaciones para USB (persistentes)
# ===========================================================================
optimize_system_performance() {
    echo "Aplicando optimizaciones persistentes para USB (menos escrituras, más respuesta)..."

    # 1) sysctl: menos swap y escrituras agrupadas pero con límite bajo de datos
    #    pendientes, para que la USB lenta no congele el sistema al copiar archivos.
    sudo tee "$USB_SYSCTL_CONF" > /dev/null <<'EOF'
# Generado por config.sh (modo USB)
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_background_bytes = 16777216
vm.dirty_bytes = 50331648
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
EOF
    sudo sysctl --system > /dev/null && echo " -> sysctl aplicado ($USB_SYSCTL_CONF)"

    # 2) journald en RAM: los logs no se escriben en la USB (se pierden al reiniciar)
    sudo mkdir -p "$(dirname "$USB_JOURNALD_CONF")"
    sudo tee "$USB_JOURNALD_CONF" > /dev/null <<'EOF'
# Generado por config.sh (modo USB)
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF
    sudo systemctl restart systemd-journald && echo " -> journald en RAM"

    # 3) Planificador de E/S BFQ para discos USB (mejor respuesta bajo escritura)
    sudo tee "$USB_UDEV_RULE" > /dev/null <<'EOF'
# Generado por config.sh (modo USB)
ACTION=="add|change", KERNEL=="sd[a-z]", ENV{ID_BUS}=="usb", ATTR{queue/scheduler}="bfq"
EOF
    sudo modprobe bfq 2>/dev/null
    sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=block --action=change
    echo " -> Planificador BFQ para dispositivos USB"

    # 4) zram: swap comprimido en RAM (tiene prioridad sobre cualquier swap en la USB)
    if sudo pacman -S --needed --noconfirm zram-generator; then
        sudo tee "$USB_ZRAM_CONF" > /dev/null <<'EOF'
# Generado por config.sh (modo USB)
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
        sudo systemctl daemon-reload
        sudo systemctl start systemd-zram-setup@zram0.service && echo " -> zram activo"
    else
        fail "zram-generator"
    fi

    # 5) noatime: evita una escritura por cada lectura de archivo.
    #    Se aplica a todos los montajes ext4/btrfs/xfs/f2fs de fstab (incluye subvolúmenes btrfs).
    local fs_re='^[^#[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+(ext4|btrfs|xfs|f2fs)[[:space:]]'
    if grep -E "$fs_re" /etc/fstab | grep -qv noatime; then
        sudo cp /etc/fstab /etc/fstab.bak-config-sh
        sudo sed -i -E "/$fs_re/ {
            /noatime/ b
            s/(^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+)([^[:space:]]+)/\1\2,noatime/
            s/,(relatime|atime|strictatime)//g
            s/[[:space:]](relatime|atime|strictatime),/ /
        }" /etc/fstab
        if sudo findmnt --verify --tab-file /etc/fstab &> /dev/null; then
            local mp
            for mp in $(awk -v re="$fs_re" '$0 ~ re {print $2}' /etc/fstab); do
                mountpoint -q "$mp" && sudo mount -o remount,noatime "$mp"
            done
            echo " -> noatime aplicado (respaldo: /etc/fstab.bak-config-sh)"
        else
            sudo cp /etc/fstab.bak-config-sh /etc/fstab
            echo -e "${YELLOW} -> fstab no pasó la verificación, se restauró el original${NC}"
        fi
    else
        echo " -> Los sistemas de archivos ya usan noatime"
    fi

    # 6) /tmp en RAM (Manjaro normalmente ya lo trae)
    if [[ "$(findmnt -no FSTYPE /tmp)" != "tmpfs" ]]; then
        sudo systemctl enable --now tmp.mount 2>/dev/null && echo " -> /tmp montado en RAM"
    else
        echo " -> /tmp ya está en RAM"
    fi

    # 7) Perfiles de navegador en RAM (se sincronizan a disco periódicamente)
    if sudo pacman -S --needed --noconfirm profile-sync-daemon; then
        systemctl --user enable psd.service &> /dev/null
        echo " -> profile-sync-daemon habilitado (activo desde el próximo inicio de sesión)"
    else
        fail "profile-sync-daemon"
    fi

    echo "Optimizaciones USB aplicadas."
}

# Elimina las optimizaciones USB si se aplicaron antes (modo Escritorio)
revert_usb_optimizations() {
    local reverted=0 f
    for f in "$USB_SYSCTL_CONF" "$USB_JOURNALD_CONF" "$USB_UDEV_RULE" "$USB_ZRAM_CONF"; do
        if [[ -f "$f" ]] && grep -q "Generado por config.sh" "$f"; then
            sudo rm -f "$f"
            reverted=1
        fi
    done
    if (( reverted )); then
        sudo sysctl --system > /dev/null
        sudo systemctl restart systemd-journald
        sudo udevadm control --reload
        sudo systemctl daemon-reload
        echo "Se revirtieron optimizaciones USB previas (zram se desactiva al reiniciar)."
    else
        echo "Sin optimizaciones USB que revertir."
    fi
}

# ===========================================================================
# Funciones de Instalación
# ===========================================================================
install_yay() {
    echo -n "yay: "
    if command -v yay &> /dev/null; then skip_msg; return 0; fi

    sudo pacman -S --needed --noconfirm base-devel git

    # Instalar desde repositorios oficiales de Manjaro
    if sudo pacman -S --needed --noconfirm yay; then
        echo "yay instalado correctamente."
    else
        echo "Fallo al instalar yay desde pacman. Intentando compilar desde AUR..."
        local tmp
        tmp=$(mktemp -d)
        git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" \
            && (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
        rm -rf "$tmp"
    fi

    command -v yay &> /dev/null || fail "yay (los paquetes AUR no se podrán instalar)"
}

install_dev_tools() {
    ensure "Git"     git    pacman git
    ensure "Node.js" node   pacman nodejs npm
    ensure "pnpm"    pnpm   pacman pnpm
    ensure "Bun"     bun    pacman bun

    # Docker
    if ensure "Docker" "" pacman docker docker-compose docker-buildx; then
        sudo systemctl enable --now docker.service
        if ! id -nG "$USER" | grep -qw docker; then
            sudo usermod -aG docker "$USER"
            echo -e "${YELLOW} -> Agregado al grupo docker (reinicia sesión para usarlo sin sudo)${NC}"
        fi
    fi

    ensure "Flutter" flutter aur flutter-bin

    # Rust (vía rustup)
    if ensure "Rust" rustc pacman rustup; then
        rustup default &> /dev/null || rustup default stable
    fi
}

# Deja npm/pnpm/bun listos para instalar paquetes globales SIN sudo
configure_js_env() {
    echo "Configurando rutas de paquetes globales (npm, pnpm, bun)..."

    if command -v npm &> /dev/null; then
        npm config set prefix "$HOME/.npm-global"
        add_to_shell_rc 'export PATH="$HOME/.npm-global/bin:$PATH"'
        echo " -> npm -g instala en ~/.npm-global"
    fi

    if command -v pnpm &> /dev/null; then
        add_to_shell_rc 'export PNPM_HOME="$HOME/.local/share/pnpm"'
        add_to_shell_rc 'export PATH="$PNPM_HOME:$PATH"'
        echo " -> pnpm -g instala en ~/.local/share/pnpm"
    fi

    if command -v bun &> /dev/null; then
        add_to_shell_rc 'export PATH="$HOME/.bun/bin:$PATH"'
        echo " -> bun -g instala en ~/.bun/bin"
    fi

    add_to_shell_rc 'export PATH="$HOME/.local/bin:$PATH"'
}

install_editors() {
    ensure "Cursor IDE"      cursor          aur cursor-bin
    ensure "Antigravity IDE" antigravity-ide aur antigravity-ide
}

install_ai_tools() {
    ensure "Claude Desktop"  claude-desktop aur claude-desktop
    ensure "Claude Code CLI" claude         aur claude-code
    ensure "Opencode"        opencode       aur opencode-bin
}

install_productivity() {
    ensure "AppFlowy" "" aur appflowy-bin
}

install_whatsapp() {
    ensure "WhatsDesk (WhatsApp)" whatsdesk aur whatsdesk-bin
}

install_tailscale() {
    if ensure "Tailscale" tailscale pacman tailscale; then
        sudo systemctl enable --now tailscaled.service
        if ! tailscale status &> /dev/null; then
            echo -e "${YELLOW} -> Ejecuta 'sudo tailscale up' para iniciar sesión en tu red${NC}"
        fi
    fi
}

install_browsers() {
    ensure "Brave Nightly" brave-nightly        aur brave-nightly-bin
    ensure "Google Chrome" google-chrome-stable aur google-chrome

    echo -n "Eliminando Firefox: "
    if pacman -Q firefox &> /dev/null; then
        if sudo pacman -Rns --noconfirm firefox; then
            echo "Eliminado."
        else
            echo -e "${YELLOW}No se pudo eliminar (otro paquete depende de él).${NC}"
        fi
    else
        echo "No estaba instalado."
    fi
}

cleanup_residuals() {
    echo "Limpiando caché de pacman y yay..."
    sudo pacman -Sc --noconfirm
    command -v yay &> /dev/null && yay -Sc --noconfirm

    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null)
    if [[ -n "$orphans" ]]; then
        # shellcheck disable=SC2086
        sudo pacman -Rns --noconfirm $orphans
    else
        echo "No hay paquetes huérfanos."
    fi
}

print_summary() {
    echo -e "\n${CYAN}===========================================${NC}"
    if (( ${#FAILED[@]} == 0 )); then
        echo -e "${GREEN}¡Configuración e instalación completadas para Manjaro!${NC}"
    else
        echo -e "${YELLOW}Instalación terminada con errores en:${NC}"
        printf "${RED}  - %s${NC}\n" "${FAILED[@]}"
        echo "Revisa la salida de arriba y vuelve a ejecutar el script (omite lo ya instalado)."
    fi
    echo -e "${YELLOW}Nota: cierra sesión y vuelve a entrar para que Docker funcione sin sudo"
    echo -e "y para que se carguen las nuevas rutas (PATH) de npm/pnpm/bun.${NC}"
    if [[ "$INSTALL_MODE" == "portable" ]]; then
        echo -e "${YELLOW}Modo USB: reinicia para aplicar todo (zram, noatime, psd).${NC}"
    fi
    echo -e "${CYAN}===========================================${NC}\n"
}

self_destruct() {
    # No borrar nunca el script si forma parte de un repositorio git
    if git -C "$(dirname "$0")" rev-parse --is-inside-work-tree &> /dev/null; then
        return
    fi
    read -r -p "¿Eliminar este script ($0)? [s/N]: " answer
    if [[ "$answer" =~ ^[sS]$ ]]; then
        rm -- "$0" && echo "Script eliminado."
    fi
}

# ===========================================================================
# Menú de Selección
# ===========================================================================
choose_mode() {
    echo -e "\n¿Qué tipo de configuración deseas cargar?"
    echo "  1) Modo Escritorio (Sin optimizaciones USB)"
    echo "  2) Medio Portable (Con optimizaciones para USB)"
    echo "  3) Solo optimizar sistema (USB) y salir"
    echo ""

    while true; do
        read -r -p "Ingresa el número de tu elección [1-3]: " choice
        case $choice in
            1)
                INSTALL_MODE="desktop"
                echo "-> Seleccionado: Modo Escritorio."
                break
                ;;
            2)
                INSTALL_MODE="portable"
                echo "-> Seleccionado: Medio Portable (USB)."
                break
                ;;
            3)
                INSTALL_MODE="optimize_only"
                echo "-> Seleccionado: Solo Optimizar."
                break
                ;;
            *)
                echo "Opción inválida. Por favor ingresa 1, 2 o 3."
                ;;
        esac
    done
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    print_banner
    request_sudo

    if [[ "$1" == "--only-optimize" ]]; then
        INSTALL_MODE="optimize_only"
    else
        choose_mode
    fi

    if [[ "$INSTALL_MODE" == "optimize_only" ]]; then
        step "Optimización de rendimiento del sistema (USB)"
        optimize_system_performance
        print_summary
        exit 0
    fi

    if [[ "$INSTALL_MODE" == "portable" ]]; then
        step "Optimización de rendimiento del sistema (USB)"
        optimize_system_performance
    else
        step "Modo Escritorio: sin optimizaciones USB"
        revert_usb_optimizations
    fi

    step "Actualización del sistema e instalación de yay (AUR helper)"
    sudo pacman -Syu --noconfirm || fail "Actualización del sistema"
    install_yay

    step "Herramientas de desarrollo: git, Node.js, pnpm, bun, Docker, Flutter, Rust"
    install_dev_tools
    configure_js_env

    step "Editores e IDEs: Cursor, Antigravity IDE"
    install_editors

    step "Herramientas de IA: Claude Desktop, Claude Code CLI, opencode"
    install_ai_tools

    step "Productividad: AppFlowy"
    install_productivity

    step "WhatsApp Desktop (WhatsDesk)"
    install_whatsapp

    step "Tailscale (VPN mesh)"
    install_tailscale

    step "Navegadores: Brave Nightly + Google Chrome (fuera Firefox)"
    install_browsers

    step "Limpieza de archivos residuales"
    cleanup_residuals

    step "Resumen"
    print_summary

    self_destruct
}

main "$@"
