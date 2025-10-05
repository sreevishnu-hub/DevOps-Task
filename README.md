# DevOps-Task
# Automating Linux User & Group Creation with `create_users.sh`
 
**Author:** LINGAMPALLI SREEVISHNU
**Date:** 05/10/2025
**Public:** Yes
# Creating Linux Users from a CSV-like File — `create_users.sh`
**Summary**  
This short guide explains `create_users.sh`: a bash script that reads a simple `username; groups` file, creates users and groups, sets secure home permissions, generates random passwords for each user, logs all actions to `/var/log/user_management.log`, and stores credentials in `/var/secure/user_passwords.csv` with owner-only access.

## Requirements & Goals
- Input format per line: `username; group1,group2`
- Create a personal group for every user (same as username)
- Create supplementary groups if they don't exist
- Create users and their home directories
- Generate and set a secure random password for each user
- Log everything to `/var/log/user_management.log`
- Store username,password pairs in `/var/secure/user_passwords.csv` with `chmod 600`
- Graceful handling when users/groups already exist

## Key implementation points
1. **Run as root**: Writing to `/var` and creating system users requires root privileges. The script exits if not run as root.
2. **Input parsing**: Lines are trimmed; blank lines and lines starting with `#` are ignored. The username and the group list are split on the first `;`. Any whitespace around commas is removed to normalize group lists.
3. **Personal group**: Each user must have a personal group named exactly as the username. The script ensures the personal group exists (using `groupadd`).
4. **Supplementary groups**: For each group listed (comma-separated), the script creates the group if missing, then ensures the user is in that group (using `usermod -aG`).
5. **Home directory & permissions**: Home directories are created with `useradd -m` and `chmod 700` is applied to make them private.
6. **Password generation & setting**: The script uses `openssl rand -base64 12` when available (fallback to `/dev/urandom`). Passwords are applied with `chpasswd`.
7. **Logging & credential storage**:
   - Action log: `/var/log/user_management.log` (append-only by the script).
   - Credentials: `/var/secure/user_passwords.csv`, CSV header `username,password`. The directory has `700` and the file `600` permissions so only the owner (root) can read it.

## Security considerations
- Passwords are stored in plain text in `/var/secure/user_passwords.csv` so access must be tightly controlled. In production you should:
  - Use a secure vault (HashiCorp Vault, AWS Secrets Manager, or at least GPG-encrypt the file).
  - Rotate passwords on first login (e.g., force change at next login).
  - Consider generating SSH keys instead of passwords.
- The script restricts home directories to `700` to keep files private.

## How to publish the article (quick)
- **GitHub Gist**: Create a public gist with the content above at https://gist.github.com/ — one-click paste + publish, then copy the public URL.
- **GitHub repo**: Add `article.md` and `create_users.sh` to a repo, then push it public; the README will be accessible at `https://github.com/<you>/<repo>/blob/main/article.md`.

## Example usage (quick)
```bash
sudo bash create_users.sh users.txt
# Check log:
sudo tail -n 50 /var/log/user_management.log
# See credentials (root only):
sudo cat /var/secure/user_passwords.csv

https://gist.github.com/sreevishnu-hub/36c0b90f44cf966df39183238afcd622
