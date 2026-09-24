#!/usr/bin/env bash
#
# failover.sh
#
# Moves the writer between the two members of a Catalyst region group on Azure,
# and reports which member currently holds it.
#
# Run it from the working directory of ONE region — the region you are acting
# on — the same directory you run `make apply` in. It drives that region's
# Terraform and never calls the Azure API directly, so the state file stays true
# and the next ordinary `make plan` is clean.
#
# Commands:
#   status    Which member is the writer, and which are drained
#   promote   Promote this region's databases to writers (the failover step)
#   follow    Rebuild this region's databases as replicas of the other region's
#             (the failback step; it DESTROYS this region's databases)
#
# How this differs from the AWS script
# ------------------------------------
# On AWS a replica is promoted by CLEARING its replication source. Here that
# destroys the database: `source_server_id` forces a new server. Azure promotes
# in place, with a PATCH that sets `replication_role = "None"` on a server that
# keeps both its Replica create mode and its source server id. So:
#
#   promote  sets postgresql_promote_replica = true and LEAVES
#            postgresql_replicate_source_server_id exactly where it is.
#
# That is why the refusal below matters more here than it does on AWS: the
# mistake it catches is the one the AWS spelling leads you into.
#
# What it will not do
# -------------------
# `promote` reads the plan before applying it and refuses three shapes that a
# human reading the same plan at 3am can miss:
#
#   1. A plan that REPLACES a server rather than updating it in place.
#      Replacement destroys the data you are failing over to. On Azure it means
#      the replication source was cleared, or the SKU or storage was changed to
#      something that forces a new server.
#   2. A plan that does not actually promote — one where no server ends up with
#      a replication role of None.
#   3. A plan that touches anything outside the Flexible Server family. A
#      promotion apply should promote and do nothing else. This usually means
#      a `make` variable you normally pass was not passed here — put it after
#      `--` and it is forwarded to `make`. The database and the wal_level
#      configuration are part of that family on purpose: a demotion drops both,
#      because a replica inherits them from the server it follows.
#
# `follow` asks Terraform to replace the servers explicitly. Azure has no demote
# API, and a server that has been promoted can never follow again, so the
# rebuild has to be a replacement — and asking for it means the check that it
# IS one means something. The database and the wal_level configuration it
# drops are forgotten rather than deleted, once you have confirmed: they go
# with the server, and resetting wal_level on it first is a restart Azure has
# failed mid-rebuild.
#
# There is no counterpart here to the AWS script's deletion-protection guard.
# Flexible Server has no delete-protection flag for a plan to be blocked on.
#
# It does not decide that a failover should happen, and nothing here reacts to
# a region becoming unreachable. Deciding is yours.
#
# Requirements: terraform, jq, curl, make.

set -euo pipefail

# ---- defaults --------------------------------------------------------------
COMMAND=""
LOCATION=""                        # required by promote and follow
INGRESS_ENDPOINT=""                # required by promote and follow
TF_DIR="terraform"                 # this region's root, as the Makefile uses it
GROUP_DIR="terraform/region-group" # the group's front door state
ASSUME_YES=false
ALLOW_OTHER_CHANGES=false
MAKE_ARGS=()                       # everything after `--`, forwarded to make

usage() {
  cat <<'EOF'
Usage: failover.sh <command> [options] [-- MAKE_VAR=value ...]

Commands:
  status     Report which member of the group is the writer and which members
             are drained. Reads the group's front door state, so run it from
             the working directory that holds it.
  promote    Promote this region's PostgreSQL servers to writers. Set
             postgresql_promote_replica = true in this region's
             terraform.tfvars first, and LEAVE
             postgresql_replicate_source_server_id where it is — this reads
             that file, it does not edit it.
  follow     Rebuild this region's PostgreSQL servers as read replicas of the
             other region's. Set postgresql_replicate_source_server_id to the
             other region's postgresql_server_id output and
             postgresql_promote_replica back to false first.
             DESTRUCTIVE: this region's database contents are discarded.

Options:
  --location LOCATION      Azure region this working directory deploys, e.g.
                           eastus2. Required by promote and follow: the
                           Makefile defaults to westus2, which would plan
                           against the wrong region.
  --ingress-endpoint NAME  region_ingress_endpoint this region was applied
                           with. Required by promote and follow.
  --dir PATH               This region's Terraform root (default: terraform)
  --group-dir PATH         The group front door's root
                           (default: terraform/region-group)
  --allow-other-changes    Apply even though the plan changes resources other
                           than the database servers. Read the plan first.
  -y, --yes                Do not prompt for confirmation
  -h, --help               Show this help

Anything after `--` is forwarded to `make`, for the variables you normally pass
to `make apply` in this directory:

  ./failover.sh promote --location eastus2 --ingress-endpoint catalyst.example.com \
      -- ENABLE_BASTION=true
EOF
}

# ---- arg parsing -----------------------------------------------------------
[[ $# -gt 0 ]] || { usage >&2; exit 2; }

case "$1" in
  status | promote | follow) COMMAND="$1"; shift ;;
  -h | --help) usage; exit 0 ;;
  *) echo "error: unknown command '$1'" >&2; usage >&2; exit 2 ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location) LOCATION="$2"; shift 2 ;;
    --ingress-endpoint) INGRESS_ENDPOINT="$2"; shift 2 ;;
    --dir) TF_DIR="$2"; shift 2 ;;
    --group-dir) GROUP_DIR="$2"; shift 2 ;;
    --allow-other-changes) ALLOW_OTHER_CHANGES=true; shift ;;
    -y | --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; MAKE_ARGS=("$@"); break ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for bin in terraform jq curl make; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found on PATH" >&2; exit 1; }
done

# Run from the guide directory whatever directory the caller is in, so the
# relative Terraform roots and the Makefile resolve the same way every time.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- helpers ---------------------------------------------------------------

# writability_of prints writable, the unexpected status code, or what no
# answer means, for one region's own hostname. Curl is given a short timeout: a
# region that is gone should report quickly rather than hold the command open.
#
# From outside, a replica does not answer 503. Its cluster load balancer probes
# this same path, counts the 503 as down, and drops every connection to the
# address — so a healthy replica and a lost region both time out here. The
# control plane can tell them apart, and is asked when this cannot. A 503 or a
# 404 is therefore only seen from inside the region's own network.
writability_of() {
  local host="$1" code
  # curl prints 000 itself when nothing answers, and exits non-zero; appending
  # a fallback on failure would make that 000000.
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    "https://${host}/diagrid/region/writable" 2>/dev/null)" || true
  code="${code:-000}"
  case "$code" in
    200) echo "writable" ;;
    503) echo "replica" ;;
    000) echo "no answer (a replica, or down: see 'diagrid region group get')" ;;
    404) echo "no writability endpoint (not a group member, or chart < 1.115.0)" ;;
    *) echo "unexpected HTTP ${code}" ;;
  esac
}

confirm() {
  local prompt="$1" reply
  $ASSUME_YES && return 0
  read -r -p "$prompt " reply
  [[ "$reply" == "yes" ]]
}

require_failover_args() {
  [[ -n "$LOCATION" ]] || {
    echo "error: --location is required. Without it the Makefile plans against" >&2
    echo "       its westus2 default, which is not this region." >&2
    exit 2
  }
  [[ -n "$INGRESS_ENDPOINT" ]] || {
    echo "error: --ingress-endpoint is required, and must match the" >&2
    echo "       region_ingress_endpoint this region was applied with." >&2
    exit 2
  }
  [[ -d "$TF_DIR" ]] || { echo "error: no Terraform root at '$TF_DIR'" >&2; exit 1; }
}

# plan_json writes a plan for this region to $PLAN_FILE and prints it as JSON.
# The plan goes through `make`, so the variables the Makefile passes are
# defined in exactly one place, and the apply later replays this saved plan
# rather than re-planning — what you inspect is what is applied. Any arguments
# are forwarded to `terraform plan`; `follow` uses that to pass -replace.
plan_json() {
  echo "==> Planning ${LOCATION}" >&2
  make plan \
    LOCATION="$LOCATION" \
    REGION_INGRESS_ENDPOINT="$INGRESS_ENDPOINT" \
    TF_PLAN_OUT="$PLAN_FILE" \
    TF_PLAN_ARGS="$*" \
    ${MAKE_ARGS[@]+"${MAKE_ARGS[@]}"} >&2
  terraform -chdir="$TF_DIR" show -json "$PLAN_FILE"
}

# summarize_changes prints one line per resource the plan changes.
summarize_changes() {
  jq -r '.[] | "    \(.actions | join("+"))  \(.address)"' <<<"$1"
}

# guard_other_changes refuses a plan that reaches past the database servers.
#
# "Past" means outside the Flexible Server family entirely. A demotion
# necessarily drops the database and the wal_level configuration this region
# managed while it was the writer — a replica inherits both from the server it
# follows, so Terraform stops managing them the moment the region becomes one.
# Those are the demotion, not a plan that wandered, and matching the whole
# azurerm_postgresql_flexible_server* prefix is what keeps `follow` from
# refusing the very shape it exists to apply. Anything else — a bastion, a
# peering, the cluster, a DNS record — still stops it.
guard_other_changes() {
  local others="$1"
  if [[ "$(jq 'length' <<<"$others")" -eq 0 ]]; then
    return 0
  fi

  echo >&2
  echo "This plan changes resources that are not database servers:" >&2
  summarize_changes "$others" >&2
  echo >&2
  if ! $ALLOW_OTHER_CHANGES; then
    echo "error: refusing to apply. A promotion should promote and nothing else." >&2
    echo "       This is usually a make variable you pass to 'make apply' in this" >&2
    echo "       directory but did not pass here — add it after '--'. If the" >&2
    echo "       changes above are ones you want, re-run with --allow-other-changes." >&2
    exit 1
  fi
  echo "warning: applying them anyway (--allow-other-changes)." >&2
}

# ---- status ----------------------------------------------------------------
cmd_status() {
  [[ -d "$GROUP_DIR" ]] || { echo "error: no front door state at '$GROUP_DIR'" >&2; exit 1; }

  local endpoints drained
  if ! endpoints="$(terraform -chdir="$GROUP_DIR" output -json region_endpoints 2>/dev/null)"; then
    echo "error: could not read region_endpoints from '$GROUP_DIR'." >&2
    echo "       The front door is one state for the group, held in one of the two" >&2
    echo "       working directories. Run this from that one, or pass --group-dir." >&2
    exit 1
  fi
  drained="$(terraform -chdir="$GROUP_DIR" output -json drained_regions)"

  local member host state
  for member in primary secondary; do
    host="$(jq -r --arg m "$member" '.[$m] // empty' <<<"$endpoints")"
    state="$(jq -r --arg m "$member" 'if .[$m] then "drained" else "in pool" end' <<<"$drained")"
    if [[ -z "$host" ]]; then
      echo "${member}: no per-region record — the region was applied without region_group_member"
      continue
    fi
    printf '%-10s %-45s %-12s %s\n' \
      "${member}:" "$host" "$(writability_of "$host")" "$state"
  done

  # A drained region is the documented reason a healthy region takes no traffic,
  # so say it here rather than leaving it to be read off the word.
  if [[ "$(jq -r '[.[] | select(.)] | length' <<<"$drained")" -gt 0 ]]; then
    echo
    echo "note: a drained region is out of the front door's backend pool — healthy,"
    echo "      but taking no connections. The group cannot fail over to it while it"
    echo "      is. Clear it with primary_drained / secondary_drained in"
    echo "      ${GROUP_DIR}/terraform.tfvars and 'make group-apply'."
  fi
}

# ---- promote ---------------------------------------------------------------
cmd_promote() {
  require_failover_args

  local plan db others bad promoted
  plan="$(plan_json)"
  db="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                 | select(.type == "azurerm_postgresql_flexible_server")
                 | select(.change.actions != ["no-op"])
                 | {address, actions: .change.actions,
                    after_role: (.change.after // {}).replication_role,
                    after_source: (.change.after // {}).source_server_id}]' <<<"$plan")"
  others="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type | startswith("azurerm_postgresql_flexible_server") | not)
                      | select(.change.actions != ["no-op"])
                      | {address, actions: .change.actions}]' <<<"$plan")"

  if [[ "$(jq 'length' <<<"$db")" -eq 0 ]]; then
    echo "error: this plan promotes nothing — no database server changes." >&2
    echo "       Set postgresql_promote_replica = true in" >&2
    echo "       ${TF_DIR}/terraform.tfvars, leaving" >&2
    echo "       postgresql_replicate_source_server_id where it is, then run this" >&2
    echo "       again. If this deployment also has separate scheduler servers," >&2
    echo "       set scheduler_postgresql_promote_replicas for each of them too." >&2
    exit 2
  fi

  # Replacement is the one shape that destroys the data being failed over to,
  # and on Azure it is what clearing the replication source produces.
  bad="$(jq -c '[.[] | select(.actions | index("delete"))]' <<<"$db")"
  if [[ "$(jq 'length' <<<"$bad")" -gt 0 ]]; then
    echo >&2
    echo "error: this plan REPLACES database servers rather than updating them:" >&2
    summarize_changes "$bad" >&2
    echo >&2
    echo "       Replacement destroys the data you are failing over to." >&2
    echo "       On Azure the usual cause is clearing" >&2
    echo "       postgresql_replicate_source_server_id — which is how the AWS guide" >&2
    echo "       promotes, and which forces a new server here. Put it back: a" >&2
    echo "       promoted server KEEPS its source server id, and" >&2
    echo "       postgresql_promote_replica is what promotes it." >&2
    echo "       Changing the SKU or shrinking storage in the same apply does this" >&2
    echo "       too; make those changes separately, after the failover." >&2
    exit 1
  fi

  # A promotion that promotes nothing is a plan that will apply cleanly and
  # leave the group with no writer.
  promoted="$(jq -c '[.[] | select(.after_role == "None")]' <<<"$db")"
  if [[ "$(jq 'length' <<<"$promoted")" -eq 0 ]]; then
    echo >&2
    echo "error: this plan changes database servers but promotes none of them:" >&2
    summarize_changes "$db" >&2
    echo >&2
    echo "       Promotion is replication_role becoming None, which is what" >&2
    echo "       postgresql_promote_replica = true sets. Nothing in this plan does" >&2
    echo "       that." >&2
    exit 1
  fi

  # Azure accepts the promotion only while create_mode is still Replica, which
  # is true exactly while the source server id is still set.
  bad="$(jq -c '[.[] | select(.after_role == "None") | select((.after_source // "") == "")]' <<<"$db")"
  if [[ "$(jq 'length' <<<"$bad")" -gt 0 ]]; then
    echo >&2
    echo "error: these servers are being promoted with no replication source:" >&2
    summarize_changes "$bad" >&2
    echo "       Azure accepts replication_role = None only on a server whose" >&2
    echo "       create mode is still Replica, which it is only while" >&2
    echo "       postgresql_replicate_source_server_id is set. This apply would be" >&2
    echo "       refused by the Azure API." >&2
    exit 1
  fi

  guard_other_changes "$others"

  echo
  echo "Promoting these servers in ${LOCATION} to writers:"
  summarize_changes "$promoted"
  echo

  confirm "Promote? Type yes to continue:" || { echo "aborted"; exit 1; }

  terraform -chdir="$TF_DIR" apply "$PLAN_FILE"

  wait_for_writable
}

# wait_for_writable polls this region's own hostname until it reports writable.
# The agent re-observes the database on its heartbeat and holds the previous
# answer through one failed check, so this can lag the apply by up to a minute.
wait_for_writable() {
  local cluster host deadline
  cluster="$(terraform -chdir="$TF_DIR" output -raw aks_cluster_name 2>/dev/null || true)"
  if [[ -z "$cluster" ]]; then
    echo "Promotion applied. Could not resolve this region's hostname to verify it;"
    echo "check it with: ./failover.sh status"
    return 0
  fi
  host="${cluster}.${INGRESS_ENDPOINT}"

  echo
  echo "==> Waiting for ${host} to report writable"
  deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    if [[ "$(writability_of "$host")" == "writable" ]]; then
      echo "    ${host} is writable. Traffic follows within about 20 seconds as the"
      echo "    regional load balancer's health flips and the front door re-reads it."
      return 0
    fi
    sleep 10
  done

  echo "    Still not writable after 3 minutes. The promotion applied; the region"
  echo "    has not reported it. Check the Catalyst agent in this region." >&2
  return 1
}

# ---- follow ----------------------------------------------------------------
# forget_writer_only_resources drops from state the database and the
# configurations this region managed only because it was the writer, then
# re-plans. They belong to the server the apply is about to destroy, and go
# with it.
#
# Left in state, Terraform deletes each one before replacing the server, and
# "deleting" a configuration means resetting it: for wal_level, a static
# parameter, that is a restart of a server seconds from being destroyed, and
# Azure has failed it with an InternalServerError, stopping the rebuild
# half-done. Nothing is lost by forgetting them — a replica inherits both.
#
# Runs after the confirmation, so an aborted follow changes nothing. The
# re-plan is checked again: it must be the same rebuild, minus these.
forget_writer_only_resources() {
  local plan="$1" address replanned db others
  shift
  local forget
  forget="$(jq -r '[.resource_changes[]? | select(.mode == "managed")
                     | select(.type | startswith("azurerm_postgresql_flexible_server_"))
                     | select(.change.actions == ["delete"])
                     | .address] | .[]' <<<"$plan")"
  [[ -n "$forget" ]] || return 0

  echo
  echo "==> Forgetting what the old server takes with it:"
  while IFS= read -r address; do
    echo "    ${address}"
    terraform -chdir="$TF_DIR" state rm -lock=true "$address" >/dev/null
  done <<<"$forget"

  replanned="$(plan_json "$@")"
  db="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                 | select(.type | startswith("azurerm_postgresql_flexible_server"))
                 | select(.change.actions != ["no-op"])
                 | {address, actions: .change.actions}]' <<<"$replanned")"
  others="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type | startswith("azurerm_postgresql_flexible_server") | not)
                      | select(.change.actions != ["no-op"])
                      | {address, actions: .change.actions}]' <<<"$replanned")"
  if [[ "$(jq '[.[] | select(.actions | index("delete") | not)] | length' <<<"$db")" -gt 0 ]]; then
    echo "error: after forgetting them, the plan no longer only rebuilds servers:" >&2
    summarize_changes "$db" >&2
    exit 2
  fi
  guard_other_changes "$others"
}

cmd_follow() {
  require_failover_args

  local plan db others kept wanted stale replace_args
  plan="$(plan_json)"

  # The servers this region's variables ask to be replicas of the other region.
  # Everything below is about these and only these.
  wanted="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type == "azurerm_postgresql_flexible_server")
                      | select((((.change.after // {}).source_server_id) // "") != "")
                      | select((((.change.after // {}).replication_role) // "") != "None")
                      | {address, actions: .change.actions}]' <<<"$plan")"

  if [[ "$(jq 'length' <<<"$wanted")" -eq 0 ]]; then
    echo "error: this plan does not rebuild this region's databases as replicas." >&2
    echo "       In ${TF_DIR}/terraform.tfvars, set" >&2
    echo "       postgresql_replicate_source_server_id to the other region's" >&2
    echo "       postgresql_server_id output, and set postgresql_promote_replica" >&2
    echo "       back to false — a server cannot both follow and be promoted." >&2
    echo "       If this deployment also has separate scheduler servers, set" >&2
    echo "       scheduler_postgresql_replicate_source_server_ids and clear" >&2
    echo "       scheduler_postgresql_promote_replicas as well." >&2
    exit 2
  fi

  # Replacement is the whole point here: Azure has no demote, and a server that
  # has been promoted can never follow again. Terraform proposes the replacement
  # by itself when the source server id changes, because that attribute forces a
  # new server — but not when it is unchanged and only the promotion flag was
  # cleared. Ask for the replacement rather than hoping the plan proposes it,
  # then the check below means something.
  stale="$(jq -r '[.[] | select((.actions | index("delete")) | not) | .address] | .[]' <<<"$wanted")"
  if [[ -n "$stale" ]]; then
    # The address is single-quoted because it reaches `terraform plan` through
    # make, which expands TF_PLAN_ARGS into a shell command line: an unquoted
    # azurerm_postgresql_flexible_server.scheduler_postgresql["pg1"] loses its
    # quotes on the way and terraform rejects what is left.
    replace_args=()
    while IFS= read -r address; do
      replace_args+=("-replace='${address}'")
    done <<<"$stale"
    echo >&2
    echo "==> Re-planning with ${replace_args[*]}" >&2
    echo "    Terraform proposed updating these in place. Azure has no demote API," >&2
    echo "    so the rebuild has to be a replacement." >&2
    plan="$(plan_json "${replace_args[@]}")"
  fi

  db="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                 | select(.type == "azurerm_postgresql_flexible_server")
                 | select(.change.actions != ["no-op"])
                 | {address, actions: .change.actions}]' <<<"$plan")"
  others="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type | startswith("azurerm_postgresql_flexible_server") | not)
                      | select(.change.actions != ["no-op"])
                      | {address, actions: .change.actions}]' <<<"$plan")"

  kept="$(jq -c '[.[] | select((.actions | index("delete")) | not)]' <<<"$db")"
  if [[ "$(jq 'length' <<<"$db")" -eq 0 || "$(jq 'length' <<<"$kept")" -gt 0 ]]; then
    echo "error: this plan still does not rebuild this region's databases as" >&2
    echo "       replicas, after asking for the replacement explicitly:" >&2
    summarize_changes "$kept" >&2
    echo "       That is a genuine problem with the plan, not a missing variable." >&2
    exit 2
  fi

  guard_other_changes "$others"

  echo
  echo "This DESTROYS these database servers in ${LOCATION} and recreates them as"
  echo "read replicas of the other region. Their current contents are discarded:"
  summarize_changes "$db"
  echo
  echo "Correct only when the other region is the writer and holds the current state."
  echo "Flexible Server keeps its automated backups for backup_retention_days after"
  echo "the server is deleted; there is no final snapshot to ask for."
  echo
  confirm "Destroy and rebuild? Type yes to continue:" || { echo "aborted"; exit 1; }

  forget_writer_only_resources "$plan" "${replace_args[@]+"${replace_args[@]}"}"

  terraform -chdir="$TF_DIR" apply "$PLAN_FILE"

  echo
  echo "Rebuilt as replicas. Let them catch up before promoting back — a promotion"
  echo "loses whatever has not replicated yet."
}

# ---- main ------------------------------------------------------------------
if [[ "$COMMAND" == "status" ]]; then
  cmd_status
  exit 0
fi

PLAN_FILE="$(mktemp -t catalyst-failover-plan.XXXXXX)"
trap 'rm -f "$PLAN_FILE"' EXIT

case "$COMMAND" in
  promote) cmd_promote ;;
  follow) cmd_follow ;;
esac
