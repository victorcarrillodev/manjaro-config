#!/bin/bash

# ===========================================================================
# Variables Globales y Colores
# ===========================================================================
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
INSTALL_MODE=""

# ===========================================================================
# Funciones Auxiliares
# ===========================================================================
print_banner() {
    echo -e "${CYAN}=== Script de Instalación y Configuración ===${NC}"
}

request_sudo() {
    sudo -v
    # Mantener el sudo vivo mientras el script se ejecuta
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
}

step() {
    echo -e "\n${GREEN}[*] $1${NC}"
}

skip_msg() {
    echo -e "${YELLOW} -> Ya instalado, omitiendo...${NC}"
}

# ===========================================================================
# Funciones de Instalación (Con validación)
# ===========================================================================
optimize_system_performance() {
    echo "Aplicando optimizaciones para USB (reduciendo escrituras en disco)..."
    # Reducir el uso de la swap y caché para prolongar la vida de la USB
    sudo sysctl -w vm.swappiness=10
    sudo sysctl -w vm.vfs_cache_pressure=50
    echo "Optimizaciones temporales aplicadas."
}

install_yay() {
    if ! command -v yay &> /dev/null; then
        echo "Instalando dependencias base y yay..."
        sudo pacman -S --needed --noconfirm base-devel git
        git clone https://aur.archlinux.org/yay.git /tmp/yay
        cd /tmp/yay && makepkg -si --noconfirm
        cd - && rm -rf /tmp/yay
    else
        skip_msg
    fi
}

install_dev_tools() {
    # Git
    echo -n "Git: "
    if ! command -v git &> /dev/null; then sudo pacman -S --noconfirm git; else skip_msg; fi

    # Node.js y npm
    echo -n "Node.js: "
    if ! command -v node &> /dev/null; then sudo pacman -S --noconfirm nodejs npm; else skip_msg; fi

    # PNPM
    echo -n "pnpm: "
    if ! command -v pnpm &> /dev/null; then sudo pacman -S --noconfirm pnpm; else skip_msg; fi

    # Bun
    echo -n "Bun: "
    if ! command -v bun &> /dev/null; then yay -S --noconfirm bun-bin; else skip_msg; fi

    # Docker
    echo -n "Docker: "
    if ! command -v docker &> /dev/null; then 
        sudo pacman -S --noconfirm docker docker-compose
        sudo systemctl enable --now docker
    else 
        skip_msg
    fi

    # Flutter (Versión binaria precompilada para evitar problemas de dependencias con Dart)
    echo -n "Flutter: "
    if ! command -v flutter &> /dev/null; then yay -S --noconfirm flutter-bin; else skip_msg; fi

    # Rust
    echo -n "Rust: "
    if ! command -v rustc &> /dev/null; then 
        sudo pacman -S --noconfirm rustup
        rustup default stable
    else 
        skip_msg
    fi
}

install_editors() {
    echo -n "Cursor IDE: "
    if ! command -v cursor &> /dev/null; then yay -S --noconfirm cursor-bin; else skip_msg; fi

    echo -n "Antigravity IDE: "
    if ! pacman -Qs antigravity-ide &> /dev/null; then yay -S --noconfirm antigravity-ide-bin || echo "No se encontró paquete oficial en AUR, requiere instalación manual."; else skip_msg; fi
}

install_ai_tools() {
    echo -n "Claude Code CLI: "
    if ! command -v claude &> /dev/null; then sudo npm install -g @anthropic-ai/claude-code; else skip_msg; fi

    echo -n "Antigravity CLI: "
    if ! command -v antigravity &> /dev/null; then sudo npm install -g @antigravity/cli || echo "Paquete npm no encontrado, revisar nombre exacto."; else skip_msg; fi

    echo -n "Opencode: "
    if ! command -v opencode &> /dev/null; then yay -S --noconfirm opencode-bin || sudo npm install -g opencode; else skip_msg; fi
}

install_whatsapp() {
    echo -n "WhatsDesk (WhatsApp): "
    if ! command -v whatsdesk &> /dev/null; then yay -S --noconfirm whatsdesk-bin; else skip_msg; fi
}

install_tailscale() {
    echo -n "Tailscale: "
    if ! command -v tailscale &> /dev/null; then 
        sudo pacman -S --noconfirm tailscale
        sudo systemctl enable --now tailscaled
    else 
        skip_msg
    fi
}

install_browsers() {
    echo -n "Brave Nightly: "
    if ! command -v brave-nightly &> /dev/null; then yay -S --noconfirm brave-nightly-bin; else skip_msg; fi

    echo -n "Google Chrome: "
    if ! command -v google-chrome-stable &> /dev/null; then yay -S --noconfirm google-chrome; else skip_msg; fi

    echo -n "Eliminando Firefox: "
    if pacman -Qs firefox &> /dev/null; then 
        sudo pacman -Rns --noconfirm firefox
        echo "Eliminado."
    else 
        echo "No estaba instalado."
    fi
}

cleanup_residuals() {
    echo "Limpiando caché de pacman y yay..."
    sudo pacman -Sc --noconfirm
    yay -Sc --noconfirm
    sudo pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null || true
}

print_summary() {
    echo -e "\n${CYAN}===========================================${NC}"
    echo -e "${GREEN}¡Configuración e instalación completadas!${NC}"
    echo -e "${CYAN}===========================================${NC}\n"
}

self_destruct() {
    echo "Autoeliminando el script..."
    rm -- "$0"
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
        read -p "Ingresa el número de tu elección [1-3]: " choice
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
        exit 0
    fi

    if [[ "$INSTALL_MODE" == "portable" ]]; then
        step "Optimización de rendimiento del sistema (USB)"
        optimize_system_performance
    else
        step "Modo Escritorio: Omitiendo optimizaciones de USB..."
    fi

    step "Actualización del sistema e instalación de yay (AUR helper)"
    sudo pacman -Syu --noconfirm
    install_yay

    step "Herramientas de desarrollo: git, Node.js, pnpm, bun, Docker, Flutter, Rust"
    install_dev_tools

    step "Editores e IDEs: Cursor, Antigravity IDE"
    install_editors

    step "Herramientas de IA: Claude Code CLI, Antigravity CLI, opencode"
    install_ai_tools

    step "WhatsApp Desktop (WhatsDesk)"
    install_whatsapp

    step "Tailscale (VPN mesh)"
    install_tailscale

    step "Navegadores: Brave Nightly + Google Chrome (fuera Firefox)"
    install_browsers

    step "Limpieza de archivos residuales"
    cleanup_residuals

    step "Resumen y autoeliminación"
    print_summary
    
    self_destruct
}

main "$@"
