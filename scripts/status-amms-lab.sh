#!/usr/bin/env bash
# ==============================================================================
# Zestawienie Serwerowni Szpitalnej Asseco AMMS (/opt/amms-lab/status-lab.sh)
# Wyświetla na żywo topologię 4 VLAN-ów, status serwerów, adresy IP, RAM i dysk
# ==============================================================================
set -euo pipefail

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_GRAY="\033[0;37m"

clear || true
echo -e "${C_CYAN}======================================================================================${C_RESET}"
echo -e "${C_BOLD}   🏥 WIRTUALNA SERWEROWNIA SZPITALNA ASSECO AMMS (SZPITAL.LAB) — PANEL STATUSU${C_RESET}"
echo -e "${C_CYAN}======================================================================================${C_RESET}"
echo -e " Host fizyczny VPS : ${C_BOLD}$(hostname)${C_RESET} ($(uname -m), $(nproc) OCPU Ampere Altra)"
echo -e " Pamięć RAM Hosta  : ${C_BOLD}$(free -h | awk '/^Mem:/ {print "Użyte: "$3" / "$2" (Wolne/Dostępne: "$7")"}')${C_RESET}"
echo -e " Dysk SSD Hosta (/): ${C_BOLD}$(df -h / | awk 'NR==2 {print "Użyte: "$3" / "$2" ("$5" zajęte, Wolne: "$4")"}')${C_RESET}"
echo -e "${C_CYAN}--------------------------------------------------------------------------------------${C_RESET}"
echo -e "${C_BOLD} 1. ZESTAWIENIE SERWERÓW W 4 STREFACH SIECIOWYCH (VLAN 10 / 20 / 30 / 40):${C_RESET}"
echo ""

printf " %-22s | %-18s | %-13s | %-14s | %-18s\n" "SERWER (KONTENER)" "DOMENA SZPITALNA" "ADRES IP" "STREFA VLAN" "STATUS"
echo "------------------------+--------------------+---------------+----------------+-------------------"

check_node() {
    local cname="$1"
    local fqdn="$2"
    local ip="$3"
    local vlan="$4"
    local status
    if ! status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null); then
        status="brak"
    fi
    if [[ "$status" == "running" ]]; then
        printf " %-22s | %-18s | %-13s | %-14s | ${C_GREEN}● DZIAŁA (UP)${C_RESET}\n" "$cname" "$fqdn" "$ip" "$vlan"
    else
        printf " %-22s | %-18s | %-13s | %-14s | ${C_YELLOW}○ OCZEKUJE (%s)${C_RESET}\n" "$cname" "$fqdn" "$ip" "$vlan" "$status"
    fi
}

check_node "szpital-oracle-db"    "db.szpital.lab"   "10.20.10.10" "VLAN 10 (DB)"
check_node "szpital-amms-his"     "amms.szpital.lab" "10.20.20.10" "VLAN 20 (HIS)"
check_node "szpital-integracja"   "int.szpital.lab"  "10.20.30.10" "VLAN 30 (DMZ)"
check_node "szpital-pc01-desktop" "pc01.szpital.lab" "10.20.40.50" "VLAN 40 (LAN)"

echo ""
echo -e "${C_CYAN}--------------------------------------------------------------------------------------${C_RESET}"
echo -e "${C_BOLD} 2. ZUŻYCIE ZASOBÓW PRZEZ URUCHOMIONE SERWERY SZPITALNE (CPU / RAM):${C_RESET}"
echo ""
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" $(docker ps --filter "name=szpital-" -q) 2>/dev/null || echo " Brak uruchomionych kontenerów szpitalnych."

echo ""
echo -e "${C_CYAN}--------------------------------------------------------------------------------------${C_RESET}"
echo -e "${C_BOLD} 3. SZYBKIE KOMENDY ADMINISTRATORA W TERMINALACH:${C_RESET}"
echo -e " • Wejście na Stację Roboczą (10.20.40.50) : ${C_GRAY}docker exec -it szpital-pc01-desktop bash${C_RESET}"
echo -e " • Wejście na Serwer AMMS HIS (10.20.20.10): ${C_GRAY}docker exec -it szpital-amms-his bash${C_RESET}"
echo -e " • Wejście na Integrację DMZ (10.20.30.10) : ${C_GRAY}docker exec -it szpital-integracja bash${C_RESET}"
echo -e " • Wejście na Bazę Oracle DB (10.20.10.10) : ${C_GRAY}docker exec -it szpital-oracle-db bash${C_RESET}"
echo -e " • Odświeżenie tego zestawienia            : ${C_GRAY}/opt/amms-lab/status-lab.sh${C_RESET}"
echo -e "${C_CYAN}======================================================================================${C_RESET}"
