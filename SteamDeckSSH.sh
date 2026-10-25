#!/bin/bash

### STYLES
echo_E() { zenity --error --width="${2:-100}" --text="$1" 2> /dev/null; }
echo_W() { zenity --warning --width="${2:-100}" --text="$1" 2> /dev/null; }
echo_I() { zenity --info --width="${2:-100}" --text="$1" 2> /dev/null; }


### FUNCTIONS

## Random string generator
# Alphanumeric only, so the result is always safe to store in a JSON file
# $1-Length
_randomPasswordGen() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; echo; }

## Checks if user exists
# $1-Username
_userExists() { [ "$(id -u "$1" 2> /dev/null)" ]; }

## Checks if user has its password set
# $1-Username
_userHasPassword() { [ "$(passwd -S "$1" | cut -d " " -f 2)" = "P" ]; }

## Returns current user sudo status
_sudoStatus() {
local _t; _t=$(sudo -nv 2>&1)
if [ -z "$_t" ]; then
	echo 2 # has_sudo__pass_set
elif echo "$_t" | grep -q '^sudo:'; then
	echo 1 # has_sudo__needs_pass
else
	echo 0 # no_sudo
fi
}

## Returns current ssh state
_sshdState() {
local _t; _t=$(systemctl is-enabled sshd)
if [ "$_t" == "enabled" ]; then
	echo 2
elif [ "$_t" == "disabled" ]; then
	echo 1
else
	echo 0 # no_sshd_service_available
fi
}

## AES-256 (DE/EN)CRYPTION
# $1-Input string; $2-Key
# The key is passed through an environment variable, so it doesn't show up in the process list
# Reference: https://www.howtogeek.com/734838/how-to-use-encrypted-passwords-in-bash-scripts/
_encrypt() {
local _p; _p=${2:-$SESSION_GUID} # set default password
printf '%s\n' "$1" | _K="$_p" openssl enc -aes-256-cbc -md sha512 -a -pbkdf2 -iter 100000 -salt -pass env:_K
}
_decrypt() {
local _p; _p=${2:-$SESSION_GUID} # set default password
printf '%s\n' "$1" | _K="$_p" openssl enc -aes-256-cbc -md sha512 -a -d -pbkdf2 -iter 100000 -salt -pass env:_K 2> /dev/null
}

## Get password variable
_getPassword() { [ -n "$passWord" ] && _decrypt "$passWord"; }
## Set password variable
_setPassword() { passWord=$(_encrypt "$1"); }

_readUserSec() { [ -s "$UserSecPath" ] && _decrypt "$(cat "$UserSecPath")" "$SEC_KEY"; }
_writeUserSec() { (umask 077; _encrypt "$1" "$SEC_KEY" > "$UserSecPath"); }

## Validate Sudo Password and claim root rights
_validateSudoPassword() {
local _t; _t=$(printf '%s\n' "$1" | sudo -Svp '' 2>&1) # test
local _vo; _vo=${2:-0} # validate_only flag
if [ -z "$_t" ]; then
	echo 1 # sudo_pswd_valid
	[ "$_vo" = 1 ] && sudo -k # Invalidate user's cached credentials
fi
}

## Read password from user input if it does have one set
_readExistingUserPassword() {
local _p; _p=$(_getPassword) # remembered password (if any)
while true; do
	# Don't try out an empty password, as every failed attempt counts towards the sudo lockout
	if [ -n "$_p" ]; then
		echo "Trying out the given password..."
		if [ "$(_validateSudoPassword "$_p")" = 1 ]; then
			_setPassword "$_p"
			[ "$REMEMBER_PASSWORD" = "1" ] && _writeUserSec "$_p"
			break
		fi
		echo_W "Invalid password!\nPlease, enter a correct sudo password in the next window." "270"
	fi
	# Prompt user for a valid password
	_p="$(zenity --password --title="$TOOL_NAME $TOOL_VERSION" 2> /dev/null)" || exit
done
clear
}

## Ask user to choose a new password (used when the account doesn't have one)
_askNewPassword() {
local _sep=$'\x1e'
local _r _p1 _p2
while true; do
	_r="$(zenity --forms \
	--title="$TOOL_NAME $TOOL_VERSION" \
	--width="350" \
	--text="Your account has no password, but sudo needs one.\nPlease, choose your own password (at least $MIN_PASSWD_LEN characters)." \
	--add-password="Password" \
	--add-password="Confirm password" \
	--separator="$_sep" 2> /dev/null)" || exit
	_p1="${_r%%"$_sep"*}"
	_p2="${_r#*"$_sep"}"
	if [ "$_p1" != "$_p2" ]; then
		echo_W "Passwords do not match!" "200"
	elif [ "${#_p1}" -lt "$MIN_PASSWD_LEN" ]; then
		echo_W "Password is too short!" "200"
	elif [ "$_p1" = "GabeNewell#1" ]; then
		echo_W "This password is publicly known.\nPlease, choose another one." "250"
	else
		_setPassword "$_p1"
		break
	fi
done
}

## Set password for user account
# $1-Username; $2-Password
_setUserPassword() { printf '%s\n%s\n' "$2" "$2" | passwd "$1" &> /dev/null; }

## Try to set password for user account
# $1-Username; $2-Password
setUserPassword() {
local _userName; _userName=${1:-$userName}
local _passWord; _passWord=${2:-$(_getPassword)}
# Check if user exists
if ! _userExists "$_userName"; then
	echo_E "User '$_userName' does not exist!"
	return 1
fi
# Check if user already has its password set
if _userHasPassword "$_userName"; then
	echo_I "User '$_userName' already has its password set." "200"
else
	# Try to set user password
	_setUserPassword "$_userName" "$_passWord"
	# Check if password has been set
	if ! _userHasPassword "$_userName"; then
		echo_E "Password couldn't be set!"
		return 1
	fi
fi
}

## Remove password from user account
# $1-Username
_removeUserPassword() { sudo -S passwd -d "$1" &> /dev/null; }

## Remove password from the user account
# $1-Username
removeUserPassword() {
local _userName; _userName=${1:-$userName}
# Check if user exists
if ! _userExists "$_userName"; then
	echo_E "User '$_userName' does not exist!"
	return 1
fi
# Check if user already has its password set
if ! _userHasPassword "$_userName"; then
	echo_I "User '$_userName' does not have a password set."
else
	# Try to remove user password
	_removeUserPassword "$_userName"
	# Check if password has been removed
	if ! _userHasPassword "$_userName"; then
		sudo -k # Invalidate user's cached credentials
	else
		echo_E "Password couldn't be removed!"
		return 1
	fi
fi
}

## Check user's sudo rights and elevate it if possible
checkSudo() {
# Check if user is a sudoer
local _t; _t="$(_sudoStatus)"
if [ "$_t" = 1 ]; then
	# Check if user has its password set
	if _userHasPassword "$userName"; then
		_readExistingUserPassword
	else
		_askNewPassword
		setUserPassword "$userName" || exit
	fi
	_validateSudoPassword "$(_getPassword)" &> /dev/null
else
	sudo -v # Extend current sudo session
fi
if [ "$(_sudoStatus)" != 2 ]; then
	echo_E "Couldn't obtain root rights." "200"
	exit
fi
}

## Offers to remove user password if user didn't have one set before this tool set it
sudoTaskFinalize() {
[ "$DEF_USR_HAS_PASSWD" = 0 ] || return
_userHasPassword "$userName" || return
zenity --question \
--title="$TOOL_NAME $TOOL_VERSION" \
--width="350" \
--text="Your account had no password before you used $TOOL_NAME.\n\nWould you like to REMOVE the password now (SteamOS default)?" 2> /dev/null &&
removeUserPassword "$userName"
}

## Refreshes org.kde.Solid.PowerManagement config status
_refreshPlasmaConfigStatus() {
qdbus org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.refreshStatus
}

## Backs up a file before it gets overwritten
# An existing backup is never overwritten, so an interrupted run can't destroy the original file.
# If there was no original file, a '.none' marker is created instead.
# $1-File; $2-Backup; $3-Use sudo (1/0)
_backupFile() {
local _s=(); [ "$3" = 1 ] && _s=(sudo)
{ [ -e "$2" ] || [ -e "$2.none" ]; } && return
if [ -e "$1" ]; then
	"${_s[@]}" cp -fp -- "$1" "$2"
else
	"${_s[@]}" touch -- "$2.none"
fi
}

## Restores a file from its backup
# Files that haven't been backed up by this tool are left untouched.
# $1-File; $2-Backup; $3-Use sudo (1/0)
_restoreFile() {
local _s=(); [ "$3" = 1 ] && _s=(sudo)
if [ -e "$2" ]; then
	"${_s[@]}" mv -f -- "$2" "$1"
elif [ -e "$2.none" ]; then
	"${_s[@]}" rm -f -- "$1" "$2.none"
fi
}

## Backs up a file and overwrites it with the patched one
# $1-File; $2-Backup; $3-Patched file; $4-Use sudo (1/0)
_patchFile() {
local _s=(); [ "$4" = 1 ] && _s=(sudo)
_backupFile "$1" "$2" "$4"
"${_s[@]}" install -m 644 -- "$3" "$1"
}

## Restores backups of all the files this tool could have overwritten
_restoreFiles() {
(_restoreFile "$SshdConfigPath" "$BackupSshdConfigPath" 1
_restoreFile "$MotdPath" "$BackupMotdPath" 1
_restoreFile "$WarningNetPath" "$BackupWarningNetPath" 1
_restoreFile "$AuthorizedKeysPath" "$BackupAuthorizedKeysPath" 1) &> /dev/null
(_restoreFile "$PowerManProfilePath" "$BackupPowerManProfilePath" 0
_refreshPlasmaConfigStatus) &> /dev/null
}

## Checks if the authorized_keys file contains at least one key and none of the keys that used to ship with this tool
_checkAuthorizedKeys() {
if grep -qF "$OLD_BUNDLED_KEY" "$PatchedAuthorizedKeysPath"; then
	echo_E "'./data/authorized_keys' still contains the public key that came with the original SteamDeckSSH.\n\nRemove it and paste your own public key instead." "400"
	return 1
fi
if ! grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$PatchedAuthorizedKeysPath"; then
	echo_E "There is no public key in './data/authorized_keys'.\n\nPaste your own public key there first." "350"
	return 1
fi
}

_sshdQuestion() {
zenity --question \
--title="$TOOL_NAME $TOOL_VERSION" \
--width="300" \
--text="$1" 2> /dev/null

case $? in
	0) echo 1;;
	*) exit;;
esac
}

_sshdEnable() {
# Ask user using zenity
local _q="SSH Server Status: DISABLED\n\nWould you like to ENABLE it?"
[ "$KEY_AUTH" != 1 ] && _q="$_q\n\n(Password login will be allowed. Use it only on a network you trust.)"
_sshdQuestion "$_q" &> /dev/null
# Key authentication is useless without a key
[ "$KEY_AUTH" = 1 ] && { _checkAuthorizedKeys || exit; }
# Become sudo
checkSudo
# Make backup of files and overwrite original ones with the modified files
(_patchFile "$SshdConfigPath" "$BackupSshdConfigPath" "$PatchedSshdConfigPath" 1
_patchFile "$MotdPath" "$BackupMotdPath" "$PatchedMotdPath" 1
_patchFile "$WarningNetPath" "$BackupWarningNetPath" "$PatchedWarningNetPath" 1) &> /dev/null
[ "$KEY_AUTH" = 1 ] && _patchFile "$AuthorizedKeysPath" "$BackupAuthorizedKeysPath" "$PatchedAuthorizedKeysPath" 1 &> /dev/null
[ "$DISABLE_SUSPENSION" = 1 ] && (_patchFile "$PowerManProfilePath" "$BackupPowerManProfilePath" "$PatchedPowerManProfilePath" 0
_refreshPlasmaConfigStatus) &> /dev/null
# Don't start the service with a broken config (host keys are needed for the test, so create the missing ones)
sudo ssh-keygen -A &> /dev/null
if ! sudo sshd -t &> /dev/null; then
	_restoreFiles
	echo_E "The patched SSH config is invalid. The original files have been restored." "350"
	exit
fi
# Remember if user had password set
echo "$DEF_USR_HAS_PASSWD" > "$PflPath"
# Enable the sshd service
sudo systemctl enable --now sshd
# Finalize
[ "$KEY_AUTH" = 1 ] && sudoTaskFinalize
}

_sshdDisable() {
local _ip; _ip="$(ip route get 1.2.3.4 | cut -d ' ' -f 7):$(grep ^Port $SshdConfigPath | cut -d ' ' -f 2)"
_sshdQuestion "SSH Server Status: ENABLED\nServer is running at: $_ip\n\nWould you like to DISABLE it?" &> /dev/null
# Become sudo
checkSudo
# Disable the sshd service
sudo systemctl disable --now sshd
# Restore backups of the original files
_restoreFiles
# Finalize
sudoTaskFinalize
rm -f "$PflPath"
}

_sshdUnavailable() {
echo_E "Couldn't find sshd service." "200"
exit
}

_sshdScenario() {
local _t; _t="$(_sshdState)"
case "$_t" in
	0) _sshdUnavailable;; # unavailable
	1) _sshdEnable;; # disabled
	2) _sshdDisable;; # enabled
esac
}


### SETTINGS

declare -r settingsJson="settings.json" # Settings fileName
declare -r settingsNames=("KEY_AUTH" "SEC_KEY" "REMEMBER_PASSWORD" "DISABLE_SUSPENSION") # Settings Names
declare -r settingsFormats=("i" "s" "i" "i") # Settings Formats (i - integer; s - string)
declare -r settingsDefaults=("0" "$(_randomPasswordGen "32")" "0" "1") # Settings Default Values

## Reads settings from a 'settingsJson' config file
_readSettingsJson() {
_jq() { jq -r ".$1 // empty" "$settingsJson" 2> /dev/null; }
local _t;
# Settings to read
for (( i=0; i<"${#settingsNames[@]}"; i++ ))
do
	_t="$(_jq "${settingsNames[$i]}")"
	[ -z "$_t" ] && _t="${settingsDefaults[$i]}"
	printf -v "${settingsNames[$i]}" -- "%${settingsFormats[$i]}" "$_t"
done
}

## Writes settings to a 'settingsJson' config file
_writeSettingsJson() {
local _n;
local _a=();
# Settings to write (jq escapes the values, so any character is safe)
for (( i=0; i<"${#settingsNames[@]}"; i++ ))
do
	_n=${settingsNames[$i]}
	_a+=(--arg "$_n" "${!_n}")
done
(umask 077; jq -n "${_a[@]}" '$ARGS.named' > "$settingsJson")
}

## Loads Settings from an existing 'settingsJson' config file or creates a new one
loadSettingsJson() {
local _f="$settingsJson"
if [ -s "./$_f" ] && jq -e . "./$_f" &> /dev/null; then
	_readSettingsJson # load settings from the existing file
else
	_readSettingsJson # in this case it sets the default settings
	_writeSettingsJson # write new settings file (or replace the broken one)
fi
}


### GLOBAL VARIABLES

## MAIN VARIABLES
SESSION_GUID="$(uuidgen | tr "[:lower:]" "[:upper:]")"; readonly SESSION_GUID
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd); readonly ROOT_DIR
cd -- "$ROOT_DIR" || exit # all the relative paths below depend on it
declare -r TOOL_NAME="SteamDeckSSH"
declare -r TOOL_VERSION="v1.0.1-fixed"

## PATHS
declare -r PflPath="./.pfl" # previous first launch
declare -r UserSecPath="./.user.sec"
declare -r SshdConfigPath="/etc/ssh/sshd_config"
# PatchedSshdConfigPath will be declared after the values from 'settings.json' file are loaded
declare -r BackupSshdConfigPath="/etc/ssh/sshd_config_original"
declare -r MotdPath="/etc/motd"
declare -r BackupMotdPath="/etc/motd_original"
declare -r PatchedMotdPath="./data/motd"
declare -r WarningNetPath="/etc/ssh/warning.net"
declare -r BackupWarningNetPath="/etc/ssh/warning.net_original"
declare -r PatchedWarningNetPath="./data/warning.net"
declare -r AuthorizedKeysPath="/etc/ssh/authorized_keys"
declare -r BackupAuthorizedKeysPath="/etc/ssh/authorized_keys_original"
declare -r PatchedAuthorizedKeysPath="./data/authorized_keys"
declare -r PowerManProfilePath="/home/$USER/.config/powermanagementprofilesrc"
declare -r BackupPowerManProfilePath="/home/$USER/.config/powermanagementprofilesrc_original"
declare -r PatchedPowerManProfilePath="./data/powermanagementprofilesrc"

## Username and password rules
userName="$USER" # real username (deck)
declare -r MIN_PASSWD_LEN=8
# Beginning of the public key that shipped in './data/authorized_keys' of the original SteamDeckSSH
declare -r OLD_BUNDLED_KEY="AAAAB3NzaC1yc2EAAAADAQABAAACAQDj7HwmOTlCJzw3VVg2xlmtMp2SCdJXI"

## FLAGS
DEF_USR_HAS_PASSWD=$( ([ "$(_sshdState)" = 2 ] && cat "$PflPath") || (_userHasPassword "$userName" && echo 1 || echo 0) ); readonly DEF_USR_HAS_PASSWD


### MAIN (ENTRY POINT)

## Check sudo
if [ "$(_sudoStatus)" = 0 ]; then
	echo_E "Sorry, but it seems that a current user hasn't got root rights. Please, contact the adminstrator of your device." "450"
	exit
fi

loadSettingsJson
passWord=""
_t="$(_readUserSec)"; [ -n "$_t" ] && _setPassword "$_t"; unset _t

get_sshd_config() {
case "$KEY_AUTH" in
	1) echo "sshd_config-ka";;
	*) echo "sshd_config-pa";;
esac
}
PatchedSshdConfigPath="./data/$(get_sshd_config)"; readonly PatchedSshdConfigPath

while true
do
	_sshdScenario
done
