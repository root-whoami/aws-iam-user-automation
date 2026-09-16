#!/bin/bash
set -u

CREDENTIALS_FILE="users_passwords.txt"
GROUP_NAME="Developers"
TOTAL_USERS=5

created_users=()
existing_users=()
failed_users=()

log_info()    { echo -e "\033[1;34m[*] $1\033[0m"; }
log_success() { echo -e "\033[1;32m[+] $1\033[0m"; }
log_warn()    { echo -e "\033[1;33m[!] $1\033[0m"; }
log_error()   { echo -e "\033[1;31m[-] $1\033[0m"; }

check_prerequisites() {
    log_info "Verifying prerequisites..."
    if ! command -v aws >/dev/null 2>&1; then
        log_error "AWS CLI not found. Install via: sudo apt install -y awscli"
        exit 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        log_error "OpenSSL not found. Install via: sudo apt install -y openssl"
        exit 1
    fi

    ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)
    if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
        log_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    log_success "Authenticated to AWS Account: $ACCOUNT_ID"
}

ensure_group_exists() {
    log_info "Checking IAM Group: $GROUP_NAME..."
    if ! aws iam get-group --group-name "$GROUP_NAME" >/dev/null 2>&1; then
        log_warn "Creating group '$GROUP_NAME'..."
        aws iam create-group --group-name "$GROUP_NAME" >/dev/null 2>&1 || {
            log_error "Failed to create group '$GROUP_NAME'."
            exit 1
        }
        log_success "Group created."
    else
        log_success "Group '$GROUP_NAME' found."
    fi
}

generate_password() {
    local base
    base=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
    echo "${base}!9Aa"
}

get_usernames() {
    declare -g -a usernames=()
    declare -A seen_names
    echo "======================================================"
    echo " Enter $TOTAL_USERS IAM usernames to create"
    echo "======================================================"

    for i in $(seq 1 "$TOTAL_USERS"); do
        while true; do
            read -r -p "User $i username: " name
            name="$(echo "$name" | xargs)"

            if [ -z "$name" ]; then
                log_error "Username cannot be empty."
                continue
            fi
            if ! [[ "$name" =~ ^[a-zA-Z0-9+=,.@-]{1,64}$ ]]; then
                log_error "Invalid characters. Use alphanumeric or standard symbols (+=,.@-)."
                continue
            fi
            if [ "${seen_names[$name]+exists}" ]; then
                log_error "Duplicate name. Enter a unique username."
                continue
            fi

            seen_names["$name"]=1
            usernames+=("$name")
            break
        done
    done
}

process_user() {
    local user="$1"
    local console_url="https://${ACCOUNT_ID}.signin.aws.amazon.com/console/"
    log_info "Processing user: $user"

    if aws iam get-user --user-name "$user" >/dev/null 2>&1; then
        log_warn "User '$user' already exists. Skipping."
        existing_users+=("$user")
        return 0
    fi

    if ! aws iam create-user --user-name "$user" >/dev/null 2>&1; then
        log_error "Failed to create IAM user '$user'."
        failed_users+=("$user")
        return 1
    fi

    local temp_pw
    temp_pw=$(generate_password)

    if ! aws iam create-login-profile --user-name "$user" --password "$temp_pw" --password-reset-required >/dev/null 2>&1; then
        log_error "Failed to set console password for '$user'."
        failed_users+=("$user")
        return 1
    fi

    aws iam add-user-to-group --user-name "$user" --group-name "$GROUP_NAME" >/dev/null 2>&1

    echo "Username: $user" >> "$CREDENTIALS_FILE"
    echo "Temporary Password: $temp_pw" >> "$CREDENTIALS_FILE"
    echo "Console URL: $console_url" >> "$CREDENTIALS_FILE"
    echo "--------------------------------------------------" >> "$CREDENTIALS_FILE"

    log_success "Created '$user'."
    created_users+=("$user")
}

main() {
    check_prerequisites
    get_usernames
    ensure_group_exists

    touch "$CREDENTIALS_FILE"
    chmod 600 "$CREDENTIALS_FILE"
    echo "# SENSITIVE IAM CREDENTIALS - DO NOT COMMIT" > "$CREDENTIALS_FILE"
    echo "# Generated: $(date -u)" >> "$CREDENTIALS_FILE"
    echo "==================================================" >> "$CREDENTIALS_FILE"

    for user in "${usernames[@]}"; do
        process_user "$user"
    done

    echo ""
    echo "======================================================"
    echo "                 EXECUTION SUMMARY                    "
    echo "======================================================"
    echo "Created (${#created_users[@]}):   ${created_users[*]:-None}"
    echo "Existed (${#existing_users[@]}):   ${existing_users[*]:-None}"
    echo "Failed  (${#failed_users[@]}):   ${failed_users[*]:-None}"
    echo "======================================================"
    echo -e "\033[1;33m[!] Output saved: $(pwd)/$CREDENTIALS_FILE (chmod 600)\033[0m"
}

main
