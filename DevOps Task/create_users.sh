#!/usr/bin/env bash
#
# create_users.sh
# Usage: sudo bash create_users.sh users.txt
#
# Reads a file where each non-empty, non-comment line is formatted:
#   username; group1,group2,group3
#
# - Creates a personal group for each user (same name as username).
# - Creates any supplementary groups listed.
# - Creates users (if they don't exist) with home directories.
# - Ensures home ownership & permissions.
# - Generates a random password for each user and sets it.
# - Logs actions to /var/log/user_management.log
# - Stores username,password pairs (CSV) at /var/secure/user_passwords.csv
#
# Security: /var/secure has mode 700, and user_passwords.csv has mode 600.
# The script must be run as root.
 
LOGFILE="/var/log/user_management.log"
SECURE_DIR="/var/secure"
PASSFILE="$SECURE_DIR/user_passwords.csv"
 
# Logging helpers
log_info() {
  printf '%s INFO: %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOGFILE"
}
log_error() {
  printf '%s ERROR: %s\n' "$(date --iso-8601=seconds)" "$*" | tee -a "$LOGFILE" >&2
}
 
# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Use sudo." >&2
  exit 1
fi
 
# Argument check
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 users_file" >&2
  exit 2
fi
 
INPUT_FILE="$1"
if [ ! -f "$INPUT_FILE" ]; then
  echo "Input file not found: $INPUT_FILE" >&2
  exit 3
fi
 
# Prepare log and secure dirs/files
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE" || { echo "Cannot write to $LOGFILE" >&2; exit 4; }
chown root:root "$LOGFILE"
chmod 644 "$LOGFILE"
 
mkdir -p "$SECURE_DIR" || { log_error "Failed to create $SECURE_DIR"; exit 5; }
chown root:root "$SECURE_DIR"
chmod 700 "$SECURE_DIR"
 
# Initialize password CSV if missing; header included
if [ ! -f "$PASSFILE" ]; then
  printf 'username,password\n' > "$PASSFILE"
  chown root:root "$PASSFILE"
  chmod 600 "$PASSFILE"
fi
 
# Read file line by line; tolerate a final line without newline
while IFS= read -r rawline || [ -n "$rawline" ]; do
  # Trim leading/trailing whitespace
  line="$(printf '%s' "$rawline" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
 
  # Skip blank lines & comments
  [ -z "$line" ] && continue
  case "$line" in
    \#*) continue ;;
  esac
 
  # Split username and groups by first semicolon
  IFS=';' read -r username groups_raw <<< "$line"
 
  # Trim fields
  username="$(printf '%s' "$username" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  groups_raw="${groups_raw:-}"
  # Remove all whitespace from group list (so "sudo, dev" -> "sudo,dev")
  groups_raw="$(printf '%s' "$groups_raw" | sed 's/[[:space:]]//g')"
 
  # Basic username validation: Linux username rules (simple)
  if ! printf '%s' "$username" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
    log_error "Skipping invalid username: '$username' (must start with a-z or _, and contain only lowercase, digits, - or _)"
    continue
  fi
 
  # Create personal group (same as username) - groupadd -f will not fail if it exists
  if getent group "$username" >/dev/null 2>&1; then
    log_info "Personal group already exists: $username"
  else
    if groupadd "$username"; then
      log_info "Created personal group: $username"
    else
      log_error "Failed to create personal group: $username"
      continue
    fi
  fi
 
  # If user exists: we'll update groups and home permissions; else create user
  if id -u "$username" >/dev/null 2>&1; then
    log_info "User already exists: $username"
    # Ensure primary group is username
    current_primary="$(id -gn "$username")"
    if [ "$current_primary" != "$username" ]; then
      if usermod -g "$username" "$username"; then
        log_info "Updated primary group for $username to $username"
      else
        log_error "Failed to set primary group for $username"
      fi
    fi
  else
    # Ensure supplementary groups exist before creating the user
    if [ -n "$groups_raw" ]; then
      IFS=',' read -ra GARR <<< "$groups_raw"
      for g in "${GARR[@]}"; do
        [ -z "$g" ] && continue
        if ! getent group "$g" >/dev/null 2>&1; then
          if groupadd "$g"; then
            log_info "Created group: $g"
          else
            log_error "Failed to create group: $g"
          fi
        fi
      done
      # Create user with home, bash shell, primary group username, and supplementary groups
      if useradd -m -s /bin/bash -g "$username" -G "$groups_raw" "$username"; then
        log_info "Created user: $username (supplementary groups: $groups_raw)"
      else
        log_error "Failed to create user: $username"
        continue
      fi
    else
      # No supplementary groups
      if useradd -m -s /bin/bash -g "$username" "$username"; then
        log_info "Created user: $username (no supplementary groups)"
      else
        log_error "Failed to create user: $username"
        continue
      fi
    fi
  fi
 
  # Ensure home directory exists, is owned and has secure permissions
  HOME_DIR="/home/$username"
  if [ -d "$HOME_DIR" ]; then
    chown "$username":"$username" "$HOME_DIR" || log_error "Failed chown on $HOME_DIR"
    chmod 700 "$HOME_DIR" || log_error "Failed chmod on $HOME_DIR"
    log_info "Set ownership and permissions for $HOME_DIR"
  else
    log_error "Home directory missing for $username: $HOME_DIR"
  fi
 
  # Add user to any supplementary groups (useful for existing users)
  if [ -n "$groups_raw" ]; then
    IFS=',' read -ra GARR <<< "$groups_raw"
    for g in "${GARR[@]}"; do
      [ -z "$g" ] && continue
      if id -nG "$username" | tr ' ' '\n' | grep -qx "$g"; then
        log_info "User $username already member of $g"
      else
        if usermod -aG "$g" "$username"; then
          log_info "Added $username to group $g"
        else
          log_error "Failed to add $username to group $g"
        fi
      fi
    done
  fi
 
  # Generate a random password (try openssl first; fallback to /dev/urandom)
  if command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -base64 12)"
  else
    password="$(tr -dc 'A-Za-z0-9!@#$%&*()_+-=' </dev/urandom | head -c 16 || true)"
    # if even that fails, create a deterministic fallback (unlikely)
    : "${password:='ChangeMe123!'}"
  fi
 
  # Set the password
  if echo "${username}:${password}" | chpasswd; then
    log_info "Password set for $username"
  else
    log_error "Failed to set password for $username"
    continue
  fi
 
  # Append to secure CSV (username,password)
  if printf '%s,%s\n' "$username" "$password" >> "$PASSFILE"; then
    chmod 600 "$PASSFILE"
    log_info "Stored credentials for $username in $PASSFILE"
  else
    log_error "Failed to write credentials for $username to $PASSFILE"
  fi
 
done < "$INPUT_FILE"
 
log_info "Processing completed for input file: $INPUT_FILE"
