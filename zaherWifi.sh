#!/usr/bin/env bash
set -u -o pipefail

if [ "$EUID" -ne 0 ]; then
    REAL_HOME="$HOME"
    SCRIPT_PATH=$(readlink -f "$0")
    exec sudo REAL_HOME="$REAL_HOME" "$SCRIPT_PATH" "$@"
fi
REAL_HOME="${REAL_HOME:-$HOME}"

for arg in "$@"; do
    case "$arg" in
        [A-Za-z_][A-Za-z0-9_]*=*) export "${arg?}" ;;
        *)
            printf 'Error: unrecognized argument: %s\n' "$arg" >&2
            printf 'Usage: %s [VAR=value ...]  e.g. %s SKIP_ROUTER_API=1\n' "$0" "$0" >&2
            exit 1
            ;;
    esac
done

ROUTER_IP="${ROUTER_IP:-192.168.111.1}"
SKIP_ROUTER_API="${SKIP_ROUTER_API:-0}"
NO_VENDOR_LOOKUP="${NO_VENDOR_LOOKUP:-0}"
LIVENESS_CHECK="${LIVENESS_CHECK:-1}"
PING_TIMEOUT="${PING_TIMEOUT:-1}"
VENDOR_CACHE_FILE="${VENDOR_CACHE_FILE:-$REAL_HOME/.cache/zaherWifi_oui_cache.tsv}"
NAMES_FILE="${NAMES_FILE:-$REAL_HOME/.cache/zaherWifi_names.tsv}"



declare -A CUSTOM_NAMES=(
#    ["XX:XX:XX:XX:XX:XX"]="LAPTOP"
)



CUSTOM_NAMES_SERIALIZED=""
for _mac in "${!CUSTOM_NAMES[@]}"; do
    CUSTOM_NAMES_SERIALIZED+="${_mac}"$'\t'"${CUSTOM_NAMES[$_mac]}"$'\n'
done

TIMEOUT="${TIMEOUT:-10}"
DEBUG="${DEBUG:-0}"
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:154.0) Gecko/20100101 Firefox/154.0"

# --- Router creds ---
USERNAME=""
PASSWORD=''

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
    C_RED='\033[1;31m'; C_DIM='\033[2m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
    C_MAG='\033[1;35m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''; C_BOLD=''; C_RESET=''; C_MAG=''
fi

error() { printf "${C_RED}Error:${C_RESET} %s\n" "$*" >&2; exit 1; }
warn()  { printf "${C_YELLOW}Warning:${C_RESET} %s\n" "$*" >&2; }
need()  { command -v "$1" >/dev/null 2>&1 || error "required command not found: $1"; }

need ip
need ping
need arp-scan
need python3

TMPDIR="$(mktemp -d)" || error "could not create temp dir"
trap 'rm -rf "$TMPDIR"' EXIT

spin() {
    local msg="$1"; shift
    "$@" &
    local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}%s${C_RESET} %s" "${frames:i++%${#frames}:1}" "$msg"
        sleep 0.08
    done
    wait "$pid"; local rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "\r  ${C_GREEN}✓${C_RESET} %-40s\n" "$msg"
    else
        printf "\r  ${C_RED}✗${C_RESET} %-40s\n" "$msg"
    fi
    return $rc
}


step() {
    local label="$1"; shift
    local t0 t1 elapsed
    t0=$(date +%s%N)
    if "$@"; then
        t1=$(date +%s%N)
        elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", (b-a)/1000000000}')
        printf "  ${C_GREEN}✓${C_RESET} %-38s ${C_DIM}%ss${C_RESET}\n" "$label" "$elapsed"
        return 0
    fi
    printf "  ${C_RED}✗${C_RESET} %-38s\n" "$label"
    return 1
}

soft_step() {
    local label="$1"; shift
    if "$@"; then
        printf "  ${C_GREEN}✓${C_RESET} %s\n" "$label"
    else
        printf "  ${C_YELLOW}~${C_RESET} %s ${C_DIM}(unavailable)${C_RESET}\n" "$label"
    fi
}

{
printf "\n${C_MAG}◆${C_RESET} ${C_BOLD}smartWifi${C_RESET} ${C_DIM}// scanning local network${C_RESET}\n\n"

# ---------------------------------------------------------------------------
# TIER 1: local identity + scan
# ---------------------------------------------------------------------------
WLAN_IFACE=$(ip -br addr show | awk '$1 ~ /^wl/ && $2 == "UP" {print $1}' | head -n 1)
[[ -n "$WLAN_IFACE" ]] || error "No active WiFi interface found."

SSID=$(iwgetid "$WLAN_IFACE" -r 2>/dev/null || echo "Unknown Network")
MY_IP=$(ip -br addr show dev "$WLAN_IFACE" | awk '{print $3}' | cut -d'/' -f1)
MY_MAC=$(ip -br link show dev "$WLAN_IFACE" | awk '{print $3}' | tr '[:lower:]' '[:upper:]')
MY_DEVICE=$(cat /sys/class/dmi/id/product_name 2>/dev/null || uname -n)
GATEWAY_IP=$(ip -4 route show default dev "$WLAN_IFACE" | awk '{print $3}' | head -n 1)
SUBNET_PREFIX=$(echo "$MY_IP" | cut -d'.' -f1-3)
ip neigh flush dev "$WLAN_IFACE" >/dev/null 2>&1 || true

ping -c 1 -W 1 "$GATEWAY_IP" >/dev/null 2>&1
GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | grep -o -E '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | tr '[:lower:]' '[:upper:]' | head -n 1 || true)
[[ -n "$GATEWAY_MAC" ]] || GATEWAY_MAC="UNKNOWN"

BAR_W=30
TOTAL=254
for i in $(seq 1 $TOTAL); do
    ping -c 1 -W 1 "${SUBNET_PREFIX}.${i}" >/dev/null 2>&1 &
    if (( i % 32 == 0 )); then
        wait
        pct=$((i * 100 / TOTAL))
        filled=$((pct * BAR_W / 100))
        printf "\r  ${C_CYAN}Sweeping %s.0/24${C_RESET} [%s%s] %3d%%" \
            "$SUBNET_PREFIX" \
            "$(printf '█%.0s' $(seq 1 $filled))" \
            "$(printf '░%.0s' $(seq 1 $((BAR_W - filled))))" \
            "$pct"
    fi
done
wait
printf "\r  ${C_GREEN}✓${C_RESET} Sweeping %s.0/24 [%s] 100%%%20s\n" "$SUBNET_PREFIX" "$(printf '█%.0s' $(seq 1 $BAR_W))" ""

SCAN_FILE="$TMPDIR/scan.txt"
ARP_FILE="$TMPDIR/arp.tsv"

do_arp_scan() { arp-scan -l -I "$WLAN_IFACE" -q --retry=3 > "$SCAN_FILE" 2>/dev/null; }
spin "Running arp-scan on $WLAN_IFACE" do_arp_scan || warn "arp-scan reported an error - results may be incomplete"
ip neigh show dev "$WLAN_IFACE" | awk '/lladdr/ {print $1, $5}' >> "$SCAN_FILE"

grep -E -o '([0-9]{1,3}\.){3}[0-9]{1,3}[[:space:]]+([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$SCAN_FILE" \
    | tr '[:lower:]' '[:upper:]' | sort -u -k1,1 \
    | awk '{print $1"\t"$2}' > "$ARP_FILE"

# ---------------------------------------------------------------------------
# TIER 2: router admin-panel login
# ---------------------------------------------------------------------------
ROUTER_OK=0
TOPO_JSON="NONE"; ACCESSDEV_XML="NONE"; WLANSTATUS_XML="NONE"; DHCP_XML="NONE"

if [[ "$SKIP_ROUTER_API" == "1" ]]; then
    printf "  ${C_DIM}SKIP_ROUTER_API=1 - showing ARP-scan data only.${C_RESET}\n"
elif [[ "$GATEWAY_IP" != "$ROUTER_IP" ]]; then
    printf "  ${C_DIM}Not on your router (gateway %s ≠ %s) - ARP-scan data only.${C_RESET}\n" "$GATEWAY_IP" "$ROUTER_IP"
elif ! command -v curl >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
    warn "curl/sha256sum not found - showing ARP-scan data only."
else
    printf "\n  ${C_MAG}◆${C_RESET} ${C_BOLD}On your router - authenticating${C_RESET}\n"
    BASE="https://${ROUTER_IP}"
    COOKIE_JAR="$TMPDIR/cookies.txt"

    CURL_COMMON=(
        --silent --show-error --fail
        --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT"
        --cookie "$COOKIE_JAR" --cookie-jar "$COOKIE_JAR"
        --user-agent "$USER_AGENT" --http1.1 --insecure
    )
    [[ "$DEBUG" == 1 ]] && CURL_COMMON+=(--trace-ascii "$TMPDIR/curl.trace")

    tier2_reach_router() {
        login_page="$(curl "${CURL_COMMON[@]}" \
            -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
            -H 'Upgrade-Insecure-Requests: 1' "$BASE/" 2>/dev/null)"
    }
    tier2_session_token() {
        local enc
        enc="$(printf '%s\n' "$login_page" | grep -oE "_sessionTmpToken[[:space:]]*=[[:space:]]*'[^']+'" | head -n1 | sed -E "s/.*'([^']+)'.*/\1/")"
        session_token="$(printf '%b' "${enc:-}")"
        [[ -n "$session_token" && "$session_token" =~ ^[0-9]+$ ]]
    }
    tier2_salt() {
        local cb salt_response
        cb="$(date +%s%3N)"
        salt_response="$(curl "${CURL_COMMON[@]}" \
            -H 'Accept: application/xml, text/xml, */*; q=0.01' -H 'X-Requested-With: XMLHttpRequest' \
            -H "Referer: $BASE/" \
            "$BASE/function_module/login_module/login_page/logintoken_lua.lua?_=${cb}" 2>/dev/null)"
        salt="$(printf '%s' "$salt_response" | sed -nE 's#.*<ajax_response_xml_root>([0-9]+)</ajax_response_xml_root>.*#\1#p')"
        [[ -n "$salt" ]]
    }
    tier2_authenticate() {
        local password_hash login_body
        password_hash="$(printf '%s' "${PASSWORD}${salt}" | sha256sum | awk '{print $1}')"
        login_body="$TMPDIR/login_result.html"
        curl "${CURL_COMMON[@]}" -L -o "$login_body" \
            -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
            -H "Origin: $BASE" -H "Referer: $BASE/" \
            --data-urlencode "Username=${USERNAME}" \
            --data-urlencode "Password=${password_hash}" \
            --data-urlencode 'action=login' \
            --data-urlencode "_sessionTOKEN=${session_token}" \
            "$BASE/" 2>/dev/null
        grep -q 'id="logOff"' "$login_body" 2>/dev/null
    }
    load_template() {
        local nextpage="$1" cb
        cb="$(date +%s%3N)"
        curl "${CURL_COMMON[@]}" -o /dev/null \
            -H 'Accept: text/html, */*; q=0.01' -H 'X-Requested-With: XMLHttpRequest' \
            -H "Referer: $BASE/" \
            "$BASE/getpage.lua?pid=123&nextpage=${nextpage}&Menu3Location=0&_=${cb}" 2>/dev/null
    }
    tier2_fetch_topo() {
        load_template "topo_t.lp"
        local cb; cb="$(date +%s%3N)"
        curl "${CURL_COMMON[@]}" -o "$TMPDIR/topo.json" \
            -H 'Accept: application/json, text/javascript, */*; q=0.01' -H 'X-Requested-With: XMLHttpRequest' \
            -H "Referer: $BASE/" \
            "$BASE/getpage.lua?pid=1005&nextpage=topo_lua.lua&_=${cb}" 2>/dev/null
        [[ -s "$TMPDIR/topo.json" ]] && TOPO_JSON="$TMPDIR/topo.json"
    }
    tier2_fetch_wlan_status() {
        load_template "Localnet_LocalnetStatusAd_t.lp"
        local cb; cb="$(date +%s%3N)"
        curl "${CURL_COMMON[@]}" -o "$TMPDIR/accessdev.xml" \
            -H 'Accept: application/xml, text/xml, */*; q=0.01' -H 'X-Requested-With: XMLHttpRequest' \
            -H "Referer: $BASE/" \
            "$BASE/common_page/Localnet_WLAN_AccessDev_lua.lua?_=${cb}" 2>/dev/null
        [[ -s "$TMPDIR/accessdev.xml" ]] && ACCESSDEV_XML="$TMPDIR/accessdev.xml"
        cb="$(date +%s%3N)"
        curl "${CURL_COMMON[@]}" -o "$TMPDIR/wlanstatus.xml" \
            -H 'Accept: application/xml, text/xml, */*; q=0.01' -H 'X-Requested-With: XMLHttpRequest' \
            -H "Referer: $BASE/" \
            "$BASE/common_page/wlanStatus_lua.lua?_=${cb}" 2>/dev/null
        [[ -s "$TMPDIR/wlanstatus.xml" ]] && WLANSTATUS_XML="$TMPDIR/wlanstatus.xml"
        [[ "$ACCESSDEV_XML" != "NONE" || "$WLANSTATUS_XML" != "NONE" ]]
    }
    tier2_fetch_dhcp() {
        load_template "Localnet_LanMgrIpv4_t.lp"
        local cb; cb="$(date +%s%3N)"
        curl "${CURL_COMMON[@]}" -o "$TMPDIR/dhcp.xml" \
            -H 'Accept: application/xml, text/xml, */*; q=0.01' -H 'X-Requested-With: XMLHttpRequest' \
            -H "Referer: $BASE/" \
            "$BASE/common_page/Localnet_LanMgrIpv4_DHCPHostInfo_lua.lua?_=${cb}" 2>/dev/null
        [[ -s "$TMPDIR/dhcp.xml" ]] && DHCP_XML="$TMPDIR/dhcp.xml"
    }

    login_ok=1
    step "Reaching router at $ROUTER_IP" tier2_reach_router || login_ok=0
    [[ $login_ok == 1 ]] && { step "Requesting session token" tier2_session_token || login_ok=0; }
    [[ $login_ok == 1 ]] && { step "Requesting login salt" tier2_salt || login_ok=0; }
    [[ $login_ok == 1 ]] && { step "Authenticating as $USERNAME" tier2_authenticate || login_ok=0; }

    if [[ $login_ok == 1 ]]; then
        soft_step "WiFi association data (RSSI/duration)" tier2_fetch_topo
        soft_step "WLAN status / real SSID data" tier2_fetch_wlan_status
        soft_step "DHCP lease data" tier2_fetch_dhcp
        ROUTER_OK=1
    else
        printf "  ${C_YELLOW}↳ Falling back to ARP-scan data only.${C_RESET}\n"
    fi
fi
} >/dev/null 2>&1

mkdir -p "$(dirname "$VENDOR_CACHE_FILE")" 2>/dev/null || true
touch "$VENDOR_CACHE_FILE" 2>/dev/null || true
mkdir -p "$(dirname "$NAMES_FILE")" 2>/dev/null || true
touch "$NAMES_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Merge + render
# ---------------------------------------------------------------------------
python3 - \
    "$ARP_FILE" "$TOPO_JSON" "$ACCESSDEV_XML" "$WLANSTATUS_XML" "$DHCP_XML" \
    "$VENDOR_CACHE_FILE" "$NO_VENDOR_LOOKUP" "$ROUTER_OK" \
    "$SSID" "$MY_IP" "$MY_MAC" "$MY_DEVICE" "$GATEWAY_MAC" "$NAMES_FILE" "$CUSTOM_NAMES_SERIALIZED" \
    "$LIVENESS_CHECK" "$PING_TIMEOUT" \
    <<'PY'
import sys, os, json, time
import xml.etree.ElementTree as ET

(arp_path, topo_path, accessdev_path, wlanstatus_path, dhcp_path,
 vendor_cache_path, no_vendor_lookup, router_ok,
 ssid, my_ip, my_mac, my_device, gw_mac, names_path, custom_names_inline,
 liveness_check, ping_timeout) = sys.argv[1:18]

no_vendor_lookup = no_vendor_lookup == "1"
router_ok = router_ok == "1"
liveness_check = liveness_check == "1"
try:
    ping_timeout = max(1, int(ping_timeout))
except (TypeError, ValueError):
    ping_timeout = 1
NONE = "NONE"
USE_COLOR = sys.stdout.isatty() and not os.environ.get('NO_COLOR')

def fg(code, text):
    """Set foreground (and optionally bold via e.g. '1;32'), reset only
    intensity+foreground afterwards so an outer row background survives."""
    if not USE_COLOR:
        return str(text)
    return f"\033[{code}m{text}\033[22;39m"

def bg(code):
    return f"\033[48;5;{code}m" if USE_COLOR else ''

RESET = '\033[0m' if USE_COLOR else ''
BOLD = lambda t: f"\033[1m{t}\033[22m" if USE_COLOR else t
DIM = lambda t: f"\033[2m{t}\033[22m" if USE_COLOR else t


def norm_mac(mac):
    return (mac or "").strip().upper()

# --- Tier 1 ---
arp_map = {}
try:
    with open(arp_path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            ip, mac = line.split("\t", 1)
            arp_map[norm_mac(mac)] = ip
except FileNotFoundError:
    pass

# --- Tier 2 ---
def parse_instances(xml_path, container_tag):
    if xml_path == NONE:
        return
    try:
        root = ET.parse(xml_path).getroot()
    except Exception:
        return
    container = root.find(f'.//{container_tag}')
    if container is None:
        return
    for inst in container.findall('./Instance'):
        fields, children = {}, list(inst)
        for i in range(0, len(children) - 1):
            if children[i].tag == 'ParaName' and children[i + 1].tag == 'ParaValue':
                fields[children[i].text or ''] = children[i + 1].text or ''
        yield fields

def fmt_duration(seconds_str):
    try:
        total = int(seconds_str)
    except (TypeError, ValueError):
        return 'N/A'
    if total < 0:
        return 'N/A'
    d, rem = divmod(total, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    if d: return f"{d}d {h}h"
    if h: return f"{h}h {m}m"
    if m: return f"{m}m {s}s"
    return f"{s}s"

assoc_map, accessdev_map, alias_to_essid, dhcp_map = {}, {}, {}, {}

if router_ok:
    topo = {}
    if topo_path != NONE:
        try:
            with open(topo_path, encoding="utf-8", errors="replace") as f:
                topo = json.load(f)
        except Exception:
            topo = {}

    def extract_ad_entries(obj):
        node = obj.get('ad')
        if isinstance(node, dict):
            for val in node.values():
                if isinstance(val, dict) and 'MacAddr' in val:
                    yield val
        master = obj.get('master')
        if isinstance(master, dict):
            inner = master.get('ad')
            if isinstance(inner, dict):
                for val in inner.values():
                    if isinstance(val, dict) and 'MacAddr' in val:
                        yield val

    for val in extract_ad_entries(topo):
        mac = norm_mac(val.get('MacAddr'))
        if not mac:
            continue
        assoc_map[mac] = {
            'HostName': val.get('HostName', '') or '',
            'IpAddr': val.get('IpAddr', '') or '',
            'Rssi': val.get('Rssi', ''),
            'AssocTime': val.get('AssocTime', ''),
        }

    for fields in parse_instances(accessdev_path, 'OBJ_ACCESSDEV_ID'):
        mac = norm_mac(fields.get('MACAddress'))
        if not mac:
            continue
        accessdev_map[mac] = {
            'HostName': fields.get('HostName', '') or '',
            'IPAddress': fields.get('IPAddress', '') or '',
            'AliasName': fields.get('AliasName', '') or '',
        }

    for fields in parse_instances(wlanstatus_path, 'OBJ_WLANAP_ID'):
        alias, essid = fields.get('Alias', ''), fields.get('ESSID', '')
        if alias and essid:
            alias_to_essid[alias] = essid

    for fields in parse_instances(dhcp_path, 'OBJ_DHCPHOSTINFO_ID'):
        mac = norm_mac(fields.get('MACAddr'))
        if not mac:
            continue
        dhcp_map[mac] = {
            'HostName': fields.get('HostName', '') or '',
            'IPAddr': fields.get('IPAddr', '') or '',
        }

# --- User-editable device names (MAC -> Name). Two sources, checked in
# priority order: the CUSTOM_NAMES list inside the script itself (highest
# priority - always wins), then the external NAMES_FILE cache.
def parse_name_lines(text):
    result = {}
    for line in text.splitlines():
        line = line.rstrip('\n')
        if not line or line.lstrip().startswith('#') or '\t' not in line:
            continue
        m, n = line.split('\t', 1)
        m, n = norm_mac(m), n.strip()
        if m and n:
            result[m] = n
    return result

names_from_file = {}
try:
    with open(names_path, encoding="utf-8") as f:
        names_from_file = parse_name_lines(f.read())
except FileNotFoundError:
    pass

names_from_code = parse_name_lines(custom_names_inline)
custom_names = {**names_from_file, **names_from_code}

def vendor_first_word(vendor):
    """First word of the vendor string, used as a fallback device name when
    nothing (router/DHCP/custom file) has a real name for this MAC."""
    if not vendor or vendor in ('N/A', 'Unknown', '-- Randomized --'):
        return None
    word = vendor.strip().split()[0].strip(',.') if vendor.strip() else None
    return word or None

# --- Vendor cache/lookup ---
vendor_cache = {}
try:
    with open(vendor_cache_path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip('\n')
            if '\t' in line:
                p, n = line.split('\t', 1)
                vendor_cache[p] = n
except FileNotFoundError:
    pass

def mac_prefix(mac):
    parts = mac.split(':')
    return ':'.join(parts[:3]) if len(parts) >= 3 else mac

def is_locally_administered(mac):
    parts = mac.split(':')
    if not parts or not parts[0]:
        return False
    try:
        first_octet = int(parts[0], 16)
    except ValueError:
        return False
    return bool(first_octet & 0x02)

import urllib.request, urllib.error

def lookup_vendor(mac):
    if is_locally_administered(mac):
        return '-- Randomized --'
    prefix = mac_prefix(mac)
    if prefix in vendor_cache:
        return vendor_cache[prefix]
    if no_vendor_lookup:
        return 'N/A'
    url = f"https://api.macvendors.com/{mac}"
    name = 'Unknown'
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'smartWifi.sh'})
            with urllib.request.urlopen(req, timeout=5) as resp:
                name = resp.read().decode('utf-8', errors='replace').strip() or 'Unknown'
            break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(1.5)
                continue
            name = 'Unknown'
            break
        except Exception:
            name = 'Unknown'
            break
    vendor_cache[prefix] = name
    time.sleep(1.1)
    return name

# --- Unified merge ---
# arp_map is the strongest local proof we have: it comes from this run's
# fresh ARP discovery after flushing the neighbor cache. assoc_map is useful
# for RSSI/SSID/association duration, but some router firmwares keep stale
# association entries for minutes after an abrupt disconnect.
#
# Therefore a wireless device that appears in assoc_map but is absent from
# this run's arp_map gets a final ICMP liveness check against its current IP.
# If it does not answer, it is treated as stale and is NOT shown as connected.
# DHCP/accessdev remain enrichment/history only and never create a row.
all_macs = set(arp_map) | set(assoc_map)
all_macs.discard(norm_mac(my_mac))
all_macs.discard(norm_mac(gw_mac))

# Some routers report a literal "0" (or blank) HostName for devices they
# don't actually have a name for - treat those as "no name" too, instead of
# taking them at face value.
JUNK_HOSTNAMES = {'', '0', 'null', 'unknown', 'n/a'}
def valid_hostname(hn):
    return hn if hn and hn.strip().lower() not in JUNK_HOSTNAMES else None

rows = []
for mac in all_macs:
    assoc = assoc_map.get(mac)
    dhcp = dhcp_map.get(mac)
    accessdev = accessdev_map.get(mac)
    arp_ip = arp_map.get(mac)

    is_wireless_router = assoc is not None

    # Router-side association state can be stale.  When the MAC was not
    # discovered by the fresh ARP pass, verify the IP before accepting the
    # router's old association entry as a currently connected client.
    if is_wireless_router and liveness_check and mac not in arp_map:
        candidate_ip = assoc.get('IpAddr', '') if assoc else ''
        if candidate_ip in ('', '0.0.0.0', 'N/A'):
            candidate_ip = (dhcp and dhcp.get('IPAddr', '')) or (accessdev and accessdev.get('IPAddress', '')) or ''

        live = False
        if candidate_ip:
            try:
                import subprocess
                result = subprocess.run(
                    ['ping', '-n', '-c', '1', '-W', str(ping_timeout), candidate_ip],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=ping_timeout + 1,
                    check=False,
                )
                live = result.returncode == 0
            except (OSError, subprocess.SubprocessError):
                live = False

        if not live:
            continue

    vendor = lookup_vendor(mac)
    # Some routers report a literal "0" (or blank) HostName for devices they
    # don't actually have a name for - treat those as "no name" too, instead
    # of taking them at face value.
    junk_hostnames = {'', '0', 'null', 'unknown', 'n/a'}
    def valid_hostname(hn):
        return hn if hn and hn.strip().lower() not in junk_hostnames else None
    reported_name = (
        valid_hostname(assoc and assoc['HostName'])
        or valid_hostname(accessdev and accessdev['HostName'])
        or valid_hostname(dhcp and dhcp['HostName'])
    )
    # Priority: a name you set yourself in the names file always wins, then
    # whatever the router/DHCP actually reported, then a guess from the
    # vendor string (e.g. "Samsung", "TP-LINK"), then plain '(unknown)'.
    name = custom_names.get(mac) or reported_name or vendor_first_word(vendor) or '(unknown)'

    if is_wireless_router:
        ip = assoc['IpAddr'] if assoc['IpAddr'] not in ('', '0.0.0.0') else (
            (dhcp and dhcp['IPAddr']) or (accessdev and accessdev['IPAddress']) or arp_ip or 'N/A'
        )
        rssi = assoc.get('Rssi') if assoc.get('Rssi') not in (None, '') else None
        duration = fmt_duration(assoc.get('AssocTime'))
        alias = accessdev['AliasName'] if accessdev else ''
        ssid_r = alias_to_essid.get(alias, alias or 'N/A')
        conn_type = 'Uplink' if ip in ('', '0.0.0.0', 'N/A') else 'Wireless'
    elif dhcp or accessdev:
        ip = (dhcp and dhcp['IPAddr']) or (accessdev and accessdev['IPAddress']) or arp_ip or 'N/A'
        rssi, duration, ssid_r = None, 'N/A', 'N/A'
        conn_type = 'Wired*'
    else:
        ip = arp_ip or 'N/A'
        rssi, duration, ssid_r = None, 'N/A', 'N/A'
        conn_type = 'Unknown'

    rows.append({
        'NAME': name, 'VENDOR': vendor, 'MAC': mac, 'IPV4': ip or 'N/A',
        'SSID': ssid_r, 'RSSI': rssi, 'TYPE': conn_type, 'DURATION': duration,
    })

try:
    with open(vendor_cache_path, 'w', encoding='utf-8') as f:
        for p, n in sorted(vendor_cache.items()):
            f.write(f"{p}\t{n}\n")
except Exception as exc:
    print(f"Warning: could not write vendor cache: {exc}", file=sys.stderr)

# --- Merge MAC-randomization duplicates ---
# Phones/laptops that use per-network MAC randomization (Android 10+, iOS 14+) can
# leave a stale ARP entry under their randomized MAC alongside a fresh entry under
# their real hardware MAC (seen by the router or a newer ARP probe). Both entries
# share the same hostname, so if a name has one '-- Randomized --' entry and one
# real-vendor entry, they're the same physical device - keep only the real one.
# Names still reported as '(unknown)' are never merged, since multiple unrelated
# devices can legitimately share that placeholder.
by_name = {}
for r in rows:
    by_name.setdefault(r['NAME'], []).append(r)

deduped = []
for name, group in by_name.items():
    if name == '(unknown)' or len(group) == 1:
        deduped.extend(group)
        continue
    randomized = [r for r in group if r['VENDOR'] == '-- Randomized --']
    real = [r for r in group if r['VENDOR'] != '-- Randomized --']
    deduped.extend(real if (randomized and real) else group)
rows = deduped

# ---------------------------------------------------------------------------
# Render: fixed-width truncated columns, one faint background for the whole
# table, per-device text colors, and RSSI signal bars.
# ---------------------------------------------------------------------------
def trunc(text, width):
    text = str(text)
    if len(text) <= width:
        return text.ljust(width)
    if width <= 1:
        return text[:width]
    return text[:width - 1] + '…'

def rssi_bar(dbm):
    if dbm is None:
        return trunc('N/A', 12)
    try:
        v = int(dbm)
    except ValueError:
        return trunc(str(dbm), 12)
    if v >= -50:
        level, code = 4, '1;32'
    elif v >= -60:
        level, code = 3, '1;32'
    elif v >= -70:
        level, code = 2, '1;33'
    elif v >= -80:
        level, code = 1, '1;31'
    else:
        level, code = 0, '1;31'
    blocks = ''.join('▂▄▆█'[j] if j < level else '·' for j in range(4))
    plain = trunc(f"{blocks} {v}dBm", 12)
    return fg(code, plain)

COLS = [
    ('NAME', 11), ('VENDOR', 16), ('MAC', 17), ('IPV4', 15), ('SSID', 8),
    ('RSSI', 12), ('CONNECTED', 9),
]

# --- Header ---
header_cells = [trunc(h, w) for h, w in COLS]
header_line = bg(24) + '\033[1;97m ' + ' │ '.join(header_cells) + f' {RESET}' if USE_COLOR else \
    ' ' + ' │ '.join(header_cells) + ' '
print(header_line)
sep_w = sum(w for _, w in COLS) + 3 * (len(COLS) - 1) + 2
print(DIM('─' * sep_w))

# One single, very faint background tint for every row in the table (instead
# of a different background per row) - just enough to separate the table from
# the terminal's own background, not to color-code anything.
ROW_BG_CODE = 236

# Each device gets its own distinct TEXT color instead (deterministic from its
# MAC, so a device keeps the same color across runs regardless of sort order).
# "This device" (mine=True) always uses plain bold bright white so it reads as
# "you" rather than blending into the per-device palette.
TEXT_PALETTE = [117, 121, 149, 180, 183, 210, 152, 223, 159, 216, 141, 108]
TEXT_FG_MINE = '1;97'  # bold bright white, reserved for "this device"

def color_for_mac(mac):
    h = 0
    for ch in mac:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    n = TEXT_PALETTE[h % len(TEXT_PALETTE)]
    return f'1;38;5;{n}'

def render_row(vals, mac, bold=False, mine=False, indent=False):
    row_bg = bg(ROW_BG_CODE) if USE_COLOR else ''
    text_color = TEXT_FG_MINE if mine else color_for_mac(mac)
    cells = []
    for key, w in COLS:
        if key == 'RSSI':
            cells.append(rssi_bar(vals['RSSI']))
        else:
            raw = vals.get(key, 'N/A')
            if key == 'NAME' and indent:
                raw = '↳' + str(raw)
            cells.append(fg(text_color, trunc(raw, w)))
    joined = ' │ '.join(cells)
    line = row_bg + ' ' + (BOLD(joined) if bold else joined) + ' ' + (RESET if row_bg else '')
    print(line)

# "This device" is pinned to the top, looked up in the router's LIVE
# association table (assoc_map) just like every other device below, so its
# RSSI/CONNECTED are real whenever the router has that data for us.
my_mac_norm = norm_mac(my_mac)
my_assoc = assoc_map.get(my_mac_norm)
if my_assoc:
    my_rssi = my_assoc.get('Rssi') if my_assoc.get('Rssi') not in (None, '') else None
    my_duration = fmt_duration(my_assoc.get('AssocTime'))
else:
    my_rssi, my_duration = None, 'N/A'

my_vendor = lookup_vendor(my_mac_norm)
my_name = custom_names.get(my_mac_norm) or my_device
render_row({
    'NAME': my_name, 'VENDOR': my_vendor, 'MAC': my_mac, 'IPV4': my_ip,
    'SSID': ssid or 'N/A', 'RSSI': my_rssi, 'CONNECTED': my_duration,
}, my_mac, bold=True, mine=True)

# ---------------------------------------------------------------------------
# Topology grouping: devices directly associated with the main router go
# first, then the TP-LINK device (acting as a bridge/AP), then everything
# that only shows up via ARP/DHCP - i.e. the devices hanging off that bridge.
# ---------------------------------------------------------------------------
def is_bridge_vendor(vendor):
    v = (vendor or '').upper()
    return 'TP-LINK' in v or 'TP LINK' in v or 'TPLINK' in v

bridge_rows = [r for r in rows if is_bridge_vendor(r['VENDOR'])]
bridge_macs = {r['MAC'] for r in bridge_rows}

direct_rows = [r for r in rows if r['MAC'] not in bridge_macs and r['TYPE'] == 'Wireless']
behind_bridge_rows = [r for r in rows if r['MAC'] not in bridge_macs and r['TYPE'] != 'Wireless']

direct_rows.sort(key=lambda r: r['NAME'].lower())
bridge_rows.sort(key=lambda r: r['NAME'].lower())
behind_bridge_rows.sort(key=lambda r: r['NAME'].lower())

# These devices aren't on a WiFi SSID at all - they're wired/relayed through
# the bridge. Show the bridge's name there instead of a bare N/A, but only
# when we don't already have a real SSID for that device.
if bridge_rows:
    bridge_label = bridge_rows[0]['NAME']
    for r in behind_bridge_rows:
        if r.get('SSID') in (None, 'N/A'):
            r['SSID'] = f'{bridge_label}'

def render_group(group, **kwargs):
    for row in group:
        vals = dict(row)
        vals['CONNECTED'] = row['DURATION']
        render_row(vals, row['MAC'], **kwargs)

render_group(direct_rows)
if bridge_rows:
    print(DIM('  ' + '·' * (sep_w - 2)))
    render_group(bridge_rows, bold=True)
    render_group(behind_bridge_rows, indent=True)
else:
    render_group(behind_bridge_rows)

print(DIM('─' * sep_w))
PY
