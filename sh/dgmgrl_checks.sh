#!/bin/sh
# Step 2: broker view of the configuration. Run on the primary host as oracle. Read-only.
#
# Usage: [DG_CONNECT=sys@<primary tns alias>] dgmgrl_checks.sh <primary db_unique_name> <standby db_unique_name>
# Shows LogXptMode, NetTimeout, ReopenSecs, LogXptStatus and validates both members and the network.
# VALIDATE NETWORK CONFIGURATION needs a password login: with the default OS login ("/") it reports
# ORA-01017 for each member. Set DG_CONNECT=sys@<alias> to be prompted for the password instead.

[ $# -eq 2 ] || { sed -n '2,8p' "$0"; exit 1; }
PRI=$1; STBY=$2; CONN=${DG_CONNECT:-/}

dgmgrl -silent "$CONN" <<EOF
show configuration verbose;
show database verbose '$STBY';
show database '$PRI' 'LogXptStatus';
validate database '$STBY';
validate network configuration for all;
exit;
EOF
