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
# Funciones de Instalación
# ===========================================================================
optimize_system_performance() {
    echo "Aplicando optimizaciones para USB (reduciendo escrituras en disco)..."
    sudo sysctl -w vm.swappiness=10
    sudo sysctl -w vm.vfs_cache_pressure=50
    echo "Optimizaciones temporales aplicadas."
}

install_yay() {
    if ! command -v yay &> /dev/null; then
        echo "Instalando dependencias base y yay..."
        sudo pacman -S --needed --noconfirm base-devel git
        
        # Instalar desde repositorios oficiales de Manjaro
        if sudo pacman -S --needed --noconfirm yay; then
            echo "yay instalado correctamente."
        else
            echo "Fallo al instalar yay desde pacman. Intentando compilar desde AUR..."
            git clone https://aur.archlinux.org/yay.git /tmp/yay
            cd /tmp/yay && makepkg -si --noconfirm
            cd - && rm -rf /tmp/yay
        fi
    else
        skip_msg
    fi
}

install_dev_tools() {
    # Git
    echo -n "Git: "
    if ! command -v git &> /dev/null; then sudo pacman -S --needed --noconfirm git; else skip_msg; fi

    # Node.js y npm
    echo -n "Node.js: "
    if ! command -v node &> /dev/null; then sudo pacman -S --needed --noconfirm nodejs npm; else skip_msg; fi

    # PNPM
    echo -n "pnpm: "
    if ! command -v pnpm &> /dev/null; then sudo pacman -S --needed --noconfirm pnpm; else skip_msg; fi

    # Bun
    echo -n "Bun: "
    if ! command -v bun &> /dev/null; then yay -S --needed --noconfirm bun-bin; else skip_msg; fi

    # Docker
    echo -n "Docker: "
    if ! command -v docker &> /dev/null; then 
        sudo pacman -S --needed --noconfirm docker docker-compose
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
        echo -e "${GREEN} Instalado (se requiere reiniciar sesión para aplicar permisos)${NC}"
    else 
        skip_msg
    fi

    # Flutter
    echo -n "Flutter: "
    if ! command -v flutter &> /dev/null; then yay -S --needed --noconfirm flutter-bin; else skip_msg; fi

    # Rust
    echo -n "Rust: "
    if ! command -v rustc &> /dev/null; then 
        sudo pacman -S --needed --noconfirm rustup
        rustup default stable
    else 
        skip_msg
    fi
}

install_editors() {
    echo -n "Cursor IDE: "
    if ! command -v cursor &> /dev/null; then yay -S --needed --noconfirm cursor-bin; else skip_msg; fi

    echo -n "Antigravity IDE: "
    if ! command -v antigravity-ide &> /dev/null; then 
        yay -S --needed --noconfirm antigravity-ide-bin || yay -S --needed --noconfirm antigravity-ide || yay -S --needed --noconfirm antigravity-bin
    else 
        skip_msg
    fi
}

install_ai_tools() {
    echo -n "Claude Desktop: "
    if ! command -v claude-desktop &> /dev/null; then 
        yay -S --needed --noconfirm claude-desktop-bin || yay -S --needed --noconfirm claude-desktop
    else 
        skip_msg
    fi

    echo -n "Claude Code CLI: "
    if ! command -v claude &> /dev/null; then sudo npm install -g @anthropic-ai/claude-code; else skip_msg; fi

    echo -n "Antigravity CLI: "
    if ! command -v antigravity &> /dev/null; then sudo npm install -g @antigravity/cli; else skip_msg; fi

    echo -n "Opencode: "
    if ! command -v opencode &> /dev/null; then yay -S --needed --noconfirm opencode-bin || sudo npm install -g opencode; else skip_msg; fi
}

install_whatsapp() {
    echo -n "WhatsDesk (WhatsApp): "
    if ! command -v whatsdesk &> /dev/null; then yay -S --needed --noconfirm whatsdesk-bin; else skip_msg; fi
}

install_tailscale() {
    echo -n "Tailscale: "
    if ! command -v tailscale &> /dev/null; then 
        sudo pacman -S --needed --noconfirm tailscale
        sudo systemctl enable --now tailscaled
    else 
        skip_msg
    fi
}

install_browsers() {
    echo -n "Brave Nightly: "
    if ! command -v brave-nightly &> /dev/null; then yay -S --needed --noconfirm brave-nightly-bin; else skip_msg; fi

    echo -n "Google Chrome: "
    if ! command -v google-chrome-stable &> /dev/null; then yay -S --needed --noconfirm google-chrome; else skip_msg; fi

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
    echo -e "${GREEN}¡Configuración e instalación completadas para Manjaro!${NC}"
    echo -e "${YELLOW}Nota: Por favor cierra sesión y vuelve a entrar para que Docker funcione sin sudo.${NC}"
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

    step "Herramientas de IA: Claude Desktop, Claude Code CLI, Antigravity CLI, opencode"
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
