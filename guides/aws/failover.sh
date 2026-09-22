#!/usr/bin/env bash
#
# failover.sh
#
# Moves the writer between the two members of a Catalyst region group, and
# reports which member currently holds it.
#
# Run it from the working directory of ONE region — the region you are acting
# on — the same directory you run `make apply` in. It drives that region's
# Terraform and never calls the RDS API directly, so the state file stays true
# and the next ordinary `make plan` is clean.
#
# Commands:
#   status    Which member is the writer, and what share of traffic each takes
#   promote   Promote this region's databases to writers (the failover step)
#   follow    Rebuild this region's databases as replicas of the other region's
#             (the failback step; it DESTROYS this region's databases)
#
# What it will not do
# -------------------
# `promote` reads the plan before applying it and refuses two shapes that a
# human reading the same plan at 3am can miss:
#
#   1. A plan that REPLACES a database instance rather than updating it in
#      place. Replacement destroys the data you are failing over to. It means
#      db_name or the master username differs between the two regions.
#   2. A plan that touches anything other than the database instances. A
#      promotion apply should promote and do nothing else. This usually means
#      a `make` variable you normally pass was not passed here — put it after
#      `--` and it is forwarded to `make`.
#
# `follow` refuses one shape and fixes another:
#
#   1. It refuses while an instance it is about to destroy still has RDS
#      deletion protection on. Terraform plans the rebuild as a replacement, so
#      it deletes before it would clear the flag, and the apply is refused by
#      the RDS API however many times you re-run it. Clearing it takes its own
#      apply first; the error prints that sequence.
#   2. It asks Terraform to replace the instances explicitly. The provider only
#      forces a new instance for replicate_source_db when the attribute was
#      absent from prior state, so a database that has been a replica before
#      plans as an in-place update AWS cannot perform — which is every second
#      failover cycle.
#
# It does not decide that a failover should happen, and nothing here reacts to
# a region becoming unreachable. Deciding is yours.
#
# Requirements: terraform, jq, curl, make.

set -euo pipefail

# ---- defaults --------------------------------------------------------------
COMMAND=""
REGION=""                          # required by promote and follow
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
  status     Report which member of the group is the writer and what share of
             traffic each member is allowed to take. Reads the group's front
             door state, so run it from the working directory that holds it.
  promote    Promote this region's PostgreSQL instances to writers. Clear
             postgresql_replicate_source_db_arn and empty
             scheduler_postgresql_replicate_source_db_arns in this region's
             terraform.tfvars first — this reads that file, it does not edit it.
  follow     Rebuild this region's PostgreSQL instances as read replicas of the
             other region's. Set those same two variables to the other region's
             postgresql_arn and scheduler_postgresql_arns outputs first.
             DESTRUCTIVE: this region's database contents are discarded.

Options:
  --region REGION          AWS region this working directory deploys, e.g.
                           us-east-1. Required by promote and follow: the
                           Makefile defaults to us-west-2, which would plan
                           against the wrong region.
  --ingress-endpoint NAME  region_ingress_endpoint this region was applied
                           with. Required by promote and follow.
  --dir PATH               This region's Terraform root (default: terraform)
  --group-dir PATH         The group front door's root
                           (default: terraform/region-group)
  --allow-other-changes    Apply even though the plan changes resources other
                           than the database instances. Read the plan first.
  -y, --yes                Do not prompt for confirmation
  -h, --help               Show this help

Anything after `--` is forwarded to `make`, for the variables you normally pass
to `make apply` in this directory:

  ./failover.sh promote --region us-east-1 --ingress-endpoint catalyst.example.com \
      -- ENABLE_BASTION=false
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
    --region) REGION="$2"; shift 2 ;;
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

# writability_of prints writable, replica, unreachable or the unexpected status
# code, for one region's own hostname. Curl is given a short timeout: a region
# that is gone should report quickly rather than hold the command open.
writability_of() {
  local host="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
    "https://${host}/diagrid/region/writable" 2>/dev/null || echo "000")"
  case "$code" in
    200) echo "writable" ;;
    503) echo "replica" ;;
    000) echo "unreachable" ;;
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
  [[ -n "$REGION" ]] || {
    echo "error: --region is required. Without it the Makefile plans against" >&2
    echo "       its us-west-2 default, which is not this region." >&2
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
  echo "==> Planning ${REGION}" >&2
  make plan \
    REGION="$REGION" \
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

# guard_other_changes refuses a plan that reaches past the database instances.
guard_other_changes() {
  local others="$1"
  if [[ "$(jq 'length' <<<"$others")" -eq 0 ]]; then
    return 0
  fi

  echo >&2
  echo "This plan changes resources that are not database instances:" >&2
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

  local endpoints dials
  if ! endpoints="$(terraform -chdir="$GROUP_DIR" output -json region_endpoints 2>/dev/null)"; then
    echo "error: could not read region_endpoints from '$GROUP_DIR'." >&2
    echo "       The front door is one state for the group, held in one of the two" >&2
    echo "       working directories. Run this from that one, or pass --group-dir." >&2
    exit 1
  fi
  dials="$(terraform -chdir="$GROUP_DIR" output -json traffic_dial_percentages)"

  local member host dial
  for member in primary secondary; do
    host="$(jq -r --arg m "$member" '.[$m] // empty' <<<"$endpoints")"
    dial="$(jq -r --arg m "$member" '.[$m]' <<<"$dials")"
    if [[ -z "$host" ]]; then
      echo "${member}: no per-region record — the Catalyst agent's gateway Load Balancer was not found"
      continue
    fi
    printf '%-10s %-45s %-12s traffic dial %s%%\n' \
      "${member}:" "$host" "$(writability_of "$host")" "$dial"
  done

  # A dial left at zero is the documented reason a healthy region takes no
  # traffic, so say it here rather than leaving it to be read off the number.
  if [[ "$(jq -r '[.[] | select(. == 0)] | length' <<<"$dials")" -gt 0 ]]; then
    echo
    echo "note: a region with a traffic dial of 0% is drained — healthy, but taking"
    echo "      no new connections. The group cannot fail over to it while it is."
  fi
}

# ---- promote ---------------------------------------------------------------
cmd_promote() {
  require_failover_args

  local plan db others bad
  plan="$(plan_json)"
  db="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                 | select(.type == "aws_db_instance")
                 | select(.change.actions != ["no-op"])
                 | {address, actions: .change.actions,
                    after_source: (.change.after // {}).replicate_source_db}]' <<<"$plan")"
  others="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type != "aws_db_instance")
                      | select(.change.actions != ["no-op"])
                      | {address, actions: .change.actions}]' <<<"$plan")"

  if [[ "$(jq 'length' <<<"$db")" -eq 0 ]]; then
    echo "error: this plan promotes nothing — no database instance changes." >&2
    echo "       Clear postgresql_replicate_source_db_arn and empty" >&2
    echo "       scheduler_postgresql_replicate_source_db_arns in" >&2
    echo "       ${TF_DIR}/terraform.tfvars, then run this again." >&2
    exit 2
  fi

  # Replacement is the one shape that destroys the data being failed over to.
  bad="$(jq -c '[.[] | select(.actions | index("delete"))]' <<<"$db")"
  if [[ "$(jq 'length' <<<"$bad")" -gt 0 ]]; then
    echo >&2
    echo "error: this plan REPLACES database instances rather than updating them:" >&2
    summarize_changes "$bad" >&2
    echo >&2
    echo "       Replacement destroys the data you are failing over to." >&2
    echo "       db_name and username force replacement when they change, and they" >&2
    echo "       go from unset to their literal values at this step — so they differ" >&2
    echo "       between your two regions. Make them match and plan again." >&2
    exit 1
  fi

  bad="$(jq -c '[.[] | select(.after_source != null)]' <<<"$db")"
  if [[ "$(jq 'length' <<<"$bad")" -gt 0 ]]; then
    echo >&2
    echo "error: this plan changes database instances but leaves replication in place:" >&2
    summarize_changes "$bad" >&2
    echo "       Promotion is the removal of the replication source. Clear it first." >&2
    exit 1
  fi

  guard_other_changes "$others"

  echo
  echo "Promoting these instances in ${REGION} to writers:"
  summarize_changes "$db"
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
  cluster="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name 2>/dev/null || true)"
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
      echo "    gateway Load Balancer's target health flips."
      return 0
    fi
    sleep 10
  done

  echo "    Still not writable after 3 minutes. The promotion applied; the region"
  echo "    has not reported it. Check the Catalyst agent in this region." >&2
  return 1
}

# ---- follow ----------------------------------------------------------------

# guard_deletion_protection refuses while an instance this command is about to
# destroy still has RDS deletion protection on. Terraform plans the change as a
# replacement, so it never applies `deletion_protection = false` before the
# delete — the apply reaches the RDS API and is refused there, mid-failover,
# with the group already on one primary. Clearing it needs its own apply first.
guard_deletion_protection() {
  local protected="$1"
  [[ "$(jq 'length' <<<"$protected")" -gt 0 ]] || return 0

  echo >&2
  echo "error: these instances still have RDS deletion protection on:" >&2
  jq -r '.[] | "    \(.address)"' <<<"$protected" >&2
  echo >&2
  echo "       Rebuilding a database as a replica destroys it first, and RDS" >&2
  echo "       refuses to delete a protected instance. Terraform plans this as a" >&2
  echo "       replacement, so it deletes before it would clear the flag and the" >&2
  echo "       apply fails at the RDS API however many times you re-run it." >&2
  echo >&2
  echo "       Clear it in its own apply, before setting the replication source:" >&2
  echo >&2
  echo "         1. In ${TF_DIR}/terraform.tfvars, leave the replication source" >&2
  echo "            variables empty and set postgresql_deletion_protection = false" >&2
  echo "         2. make apply REGION=${REGION} REGION_INGRESS_ENDPOINT=${INGRESS_ENDPOINT}" >&2
  echo "            (an in-place update; nothing is destroyed)" >&2
  echo "         3. Put the replication sources back and run this again." >&2
  exit 1
}

cmd_follow() {
  require_failover_args

  local plan db others kept wanted stale replace_args
  plan="$(plan_json)"

  # The instances this region's variables ask to be replicas of the other
  # region. Everything below is about these and only these.
  wanted="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type == "aws_db_instance")
                      | select((((.change.after // {}).replicate_source_db) // "") != "")
                      | {address, actions: .change.actions,
                         protected: ((.change.before // {}).deletion_protection == true)}]' <<<"$plan")"

  if [[ "$(jq 'length' <<<"$wanted")" -eq 0 ]]; then
    echo "error: this plan does not rebuild this region's databases as replicas." >&2
    echo "       In ${TF_DIR}/terraform.tfvars, set postgresql_replicate_source_db_arn" >&2
    echo "       to the other region's postgresql_arn output. If this deployment also" >&2
    echo "       has separate scheduler instances, set" >&2
    echo "       scheduler_postgresql_replicate_source_db_arns to its" >&2
    echo "       scheduler_postgresql_arns as well." >&2
    exit 2
  fi

  guard_deletion_protection "$(jq -c '[.[] | select(.protected)]' <<<"$wanted")"

  # Replacement is the whole point here: RDS cannot turn a writer that has
  # diverged from its former source back into a replica. But the provider only
  # forces a new instance for replicate_source_db when the attribute was absent
  # from prior state, so an instance that has been a replica before plans as an
  # in-place update AWS cannot perform. Ask for the replacement rather than
  # hoping the plan proposes it, then the check below means something.
  stale="$(jq -r '[.[] | select((.actions | index("delete")) | not) | .address] | .[]' <<<"$wanted")"
  if [[ -n "$stale" ]]; then
    # The address is single-quoted because it reaches `terraform plan` through
    # make, which expands TF_PLAN_ARGS into a shell command line: an unquoted
    # aws_db_instance.scheduler_postgresql["pg1"] loses its quotes on the way
    # and terraform rejects what is left.
    replace_args=()
    while IFS= read -r address; do
      replace_args+=("-replace='${address}'")
    done <<<"$stale"
    echo >&2
    echo "==> Re-planning with ${replace_args[*]}" >&2
    echo "    Terraform proposed updating these in place. RDS has no demote API," >&2
    echo "    so the rebuild has to be a replacement." >&2
    plan="$(plan_json "${replace_args[@]}")"
  fi

  db="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                 | select(.type == "aws_db_instance")
                 | select(.change.actions != ["no-op"])
                 | {address, actions: .change.actions}]' <<<"$plan")"
  others="$(jq -c '[.resource_changes[]? | select(.mode == "managed")
                      | select(.type != "aws_db_instance")
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
  echo "This DESTROYS these database instances in ${REGION} and recreates them as"
  echo "read replicas of the other region. Their current contents are discarded:"
  summarize_changes "$db"
  echo
  echo "Correct only when the other region is the writer and holds the current state."
  echo "postgresql_skip_final_snapshot governs whether a snapshot is kept first."
  echo
  confirm "Destroy and rebuild? Type yes to continue:" || { echo "aborted"; exit 1; }

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
