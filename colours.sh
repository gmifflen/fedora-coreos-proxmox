# ANSI color codes
export COLOR_RED='\033[0;31m'
export COLOR_GREEN='\033[0;32m'
export COLOR_YELLOW='\033[1;33m'
export COLOR_BLUE='\033[0;34m'
export COLOR_MAGENTA='\033[0;35m'
export COLOR_CYAN='\033[0;36m'
export COLOR_WHITE='\033[1;37m'
export COLOR_RESET='\033[0m'

# status colors
export COLOR_OK="${COLOR_GREEN}"
export COLOR_WARN="${COLOR_YELLOW}"
export COLOR_ERROR="${COLOR_RED}"
export COLOR_INFO="${COLOR_CYAN}"
export COLOR_DEBUG="${COLOR_MAGENTA}"

# output functions
print_ok() {
    echo -e "${COLOR_OK}[OK]${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $1" >&2
}

print_warn() {
    echo -e "${COLOR_WARN}[WARN]${COLOR_RESET} $1"
}

print_info() {
    echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $1"
}

print_debug() {
    echo -e "${COLOR_DEBUG}[DEBUG]${COLOR_RESET} $1"
}

print_status() {
    local status=$1
    local message=$2
    echo -ne "${message}... "
    if [ "$status" -eq 0 ]; then
        echo -e "${COLOR_OK}[OK]${COLOR_RESET}"
    else
        echo -e "${COLOR_ERROR}[FAILED]${COLOR_RESET}"
    fi
}

print_progress() {
    local current=$1
    local total=$2
    local message=$3
    local percentage=$((current * 100 / total))
    echo -ne "${COLOR_INFO}${message}${COLOR_RESET} [${COLOR_YELLOW}${percentage}%${COLOR_RESET}]\r"
}

print_header() {
    echo -e "\n${COLOR_BLUE}=== $1 ===${COLOR_RESET}\n"
}

print_success() {
    echo -e "\n${COLOR_GREEN}✔ $1${COLOR_RESET}\n"
}

print_failure() {
    echo -e "\n${COLOR_RED}✘ $1${COLOR_RESET}\n"
}
