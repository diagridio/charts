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
#   promote   Promote this region's databases to writers (the failover step),
#             then drain the other member, the old writer, in the front door
#   follow    Rebuild this region's databases as replicas of the other region's
#             (the failback step; it DESTROYS this region's databases), then
#             put this region back in the front door
#
# The front door
# --------------
# The old writer's database is still a primary after a promotion. Its agent
# fences it at 503, but that rests on the agent and on what the control plane
# tells it, and the accelerator would otherwise send writes to two primaries.
# So `promote` also sets the old writer's traffic dial to 0, which rests on
# neither, and it stays there until `follow` has rebuilt that region as a
# replica.
#
# Both write the group stack's failover.auto.tfvars.json rather than passing a
# -var, so the next plain `make group-apply` keeps what they did: terraform
# loads *.auto.tfvars.json by itself, after terraform.tfvars, so the file wins.
# The file also pins the drained member's gateway Load Balancer ARN, from the
# group's own state, so the apply reads nothing from that region — the old
# writer's region is often the one that is unreachable.
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
DRAIN=true                         # promote drains the old writer; --no-drain skips it
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
             Then sets the other member's traffic dial to 0 in the front door,
             through <group-dir>/failover.auto.tfvars.json, and applies it.
  follow     Rebuild this region's PostgreSQL instances as read replicas of the
             other region's. Set those same two variables to the other region's
             postgresql_arn and scheduler_postgresql_arns outputs first.
             DESTRUCTIVE: this region's database contents are discarded.
             Then removes this region's drain from failover.auto.tfvars.json
             and applies the front door.

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
                           than the database instances, or, in the front door,
                           than the drain. Read the plan first.
  --no-drain               promote only: leave the front door alone. The old
                           writer keeps its traffic dial; drain it yourself.
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
    --no-drain) DRAIN=false; shift ;;
    -y | --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; MAKE_ARGS=("$@"); break ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! $DRAIN && [[ "$COMMAND" != "promote" ]]; then
  echo "error: --no-drain applies to promote only" >&2
  exit 2
fi

for bin in terraform jq curl make; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found on PATH" >&2; exit 1; }
done

# Run from the guide directory whatever directory the caller is in, so the
# relative Terraform roots and the Makefile resolve the same way every time.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What promote and follow change in the front door. See "The front door" above.
OVERRIDES="${GROUP_DIR}/failover.auto.tfvars.json"

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

  # The file overrides terraform.tfvars, so a dial set there is not the one to
  # go looking for when this file holds the drain.
  if [[ -f "$OVERRIDES" ]]; then
    echo
    echo "note: ${OVERRIDES}, which failover.sh promote wrote, sets:"
    jq -r 'to_entries[] | "        \(.key) = \(.value)"' "$OVERRIDES"
    echo "      It overrides terraform.tfvars, so it is what drains that member."
    echo "      'failover.sh follow' in that region removes it once the region has"
    echo "      been rebuilt as a replica."
  fi
}

# ---- front door ------------------------------------------------------------

# read_overrides prints the overrides file as compact JSON, or {} when there is
# none.
read_overrides() {
  if [[ -f "$OVERRIDES" ]]; then jq -c . "$OVERRIDES"; else echo '{}'; fi
}

# write_overrides makes $1 the overrides file, and deletes the file when $1 is
# empty, so an undone drain leaves nothing behind.
write_overrides() {
  if [[ "$1" == "{}" ]]; then rm -f "$OVERRIDES"; else jq . <<<"$1" >"$OVERRIDES"; fi
}

# this_member prints primary or secondary: which member of the group this
# region is, found by its own hostname in the group stack's region_endpoints.
# It explains on stderr and returns non-zero when it cannot tell.
this_member() {
  local cluster host endpoints member
  cluster="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name 2>/dev/null || true)"
  if [[ -z "$cluster" ]]; then
    echo "warning: could not read eks_cluster_name from ${TF_DIR}, so cannot tell which" >&2
    echo "         member of the group this region is." >&2
    return 1
  fi
  host="${cluster}.${INGRESS_ENDPOINT}"
  if [[ ! -d "$GROUP_DIR" ]] ||
    ! endpoints="$(terraform -chdir="$GROUP_DIR" output -json region_endpoints 2>/dev/null)"; then
    echo "warning: could not read region_endpoints from '${GROUP_DIR}'. The front door is" >&2
    echo "         one state for the group, held in one of the two working directories." >&2
    echo "         If it is the other one, pass --group-dir <its terraform/region-group>." >&2
    return 1
  fi
  member="$(jq -r --arg h "$host" \
    'to_entries[] | select((.value | ascii_downcase) == ($h | ascii_downcase)) | .key' <<<"$endpoints")"
  if [[ "$member" != "primary" && "$member" != "secondary" ]]; then
    echo "warning: ${host} is not one member of region_endpoints in '${GROUP_DIR}':" >&2
    echo "         $(jq -c . <<<"$endpoints")" >&2
    return 1
  fi
  echo "$member"
}

# apply_group_overrides makes $1 the overrides file, plans the group stack with
# it, and applies that plan once confirmed. Declined, or a plan that fails,
# puts the file back as it was, so a later `make group-apply` does not do what
# was not done here. So does a plan that changes anything but the endpoint groups:
# -y would otherwise apply whatever else has drifted in the front door.
# Returns non-zero when the front door was not changed.
apply_group_overrides() {
  local new="$1" prompt="$2" old others rc=0
  old="$(read_overrides)"
  write_overrides "$new"

  terraform -chdir="$GROUP_DIR" plan -input=false -detailed-exitcode \
    -out="$GROUP_PLAN_FILE" || rc=$?
  case "$rc" in
    0) echo "    The front door already matches; nothing to apply."; return 0 ;;
    2) ;;
    *) write_overrides "$old"; return 1 ;;
  esac

  others="$(terraform -chdir="$GROUP_DIR" show -json "$GROUP_PLAN_FILE" |
    jq -c '[.resource_changes[]? | select(.mode == "managed")
             | select(.type != "aws_globalaccelerator_endpoint_group")
             | select(.change.actions != ["no-op"])
             | {address, actions: .change.actions}]')" || others=""
  if [[ "$others" != "[]" ]]; then
    echo >&2
    echo "This front door plan changes more than the endpoint groups:" >&2
    if [[ -n "$others" ]]; then summarize_changes "$others" >&2; fi
    if ! $ALLOW_OTHER_CHANGES || [[ -z "$others" ]]; then
      echo "error: not applying it. Run 'make group-apply' and read the plan, or re-run" >&2
      echo "       with --allow-other-changes if those changes are ones you want." >&2
      write_overrides "$old"
      return 1
    fi
    echo "warning: applying them anyway (--allow-other-changes)." >&2
  fi

  if ! confirm "$prompt"; then
    write_overrides "$old"
    return 1
  fi
  if ! terraform -chdir="$GROUP_DIR" apply -input=false "$GROUP_PLAN_FILE"; then
    echo "warning: the apply failed. ${OVERRIDES} already holds the change, so" >&2
    echo "         'make group-apply' finishes it once the error above is fixed." >&2
    return 1
  fi
}

# drain_old_writer sets the other member's traffic dial to 0 after this region
# has been promoted, and pins that member's gateway Load Balancer ARN from the
# group's state so the apply does not have to look it up in that region. It
# never fails the promotion that has already happened: when it cannot drain, it
# says what to do by hand.
drain_old_writer() {
  echo
  if ! $DRAIN; then
    echo "Not draining the old writer in the front door (--no-drain). Until you do,"
    echo "only its agent's 503 keeps traffic off it."
    return 0
  fi

  echo "==> Draining the old writer in the front door"
  local this other dials arn new
  if ! this="$(this_member)"; then
    explain_manual_drain
    return 0
  fi
  if [[ "$this" == "primary" ]]; then other="secondary"; else other="primary"; fi

  # Both dials at 0 leaves the group with nowhere to send traffic.
  dials="$(terraform -chdir="$GROUP_DIR" output -json traffic_dial_percentages 2>/dev/null || echo '{}')"
  if [[ "$(jq -r --arg m "$this" '.[$m] // empty' <<<"$dials")" == "0" ]]; then
    echo "warning: this region, the ${this}, is drained itself. Draining the ${other} as" >&2
    echo "         well would leave the group taking no traffic, so nothing was changed." >&2
    echo "         Set ${this}_traffic_dial_percentage back to 100 first; './failover.sh" >&2
    echo "         status' says whether failover.auto.tfvars.json is what sets it." >&2
    explain_manual_drain "$other"
    return 0
  fi

  arn="$(terraform -chdir="$GROUP_DIR" output -json gateway_load_balancers 2>/dev/null |
    jq -r --arg m "$other" '.[$m] // empty' || true)"
  if ! new="$(read_overrides | jq -c --arg m "$other" --arg arn "$arn" '
      .["\($m)_traffic_dial_percentage"] = 0
      | if $arn != "" then .["\($m)_gateway_lb_arn"] = $arn else . end')"; then
    explain_manual_drain "$other"
    return 0
  fi

  echo "    This region is the ${this}. Setting ${other}_traffic_dial_percentage = 0"
  echo "    in ${OVERRIDES}. It stays drained until 'failover.sh follow' rebuilds it."
  if ! apply_group_overrides "$new" "Drain the ${other}? Type yes to continue:"; then
    explain_manual_drain "$other"
  fi
}

# explain_manual_drain says how to drain the old writer by hand. $1 is its
# member, when that is known.
explain_manual_drain() {
  local member="${1:-<primary|secondary>}"
  echo "warning: the old writer was not drained in the front door. The promotion" >&2
  echo "         itself is applied. Drain it by hand, in the working directory that" >&2
  echo "         holds the front door: set ${member}_traffic_dial_percentage = 0 in" >&2
  echo "         terraform/region-group/terraform.tfvars and run 'make group-apply'." >&2
  echo "         If that region is unreachable, also set ${member}_gateway_lb_arn to" >&2
  echo "         its entry in 'make group-output gateway_load_balancers'. Put the dial" >&2
  echo "         back to 100 once 'failover.sh follow' has rebuilt that region." >&2
}

# restore_this_region undoes drain_old_writer for this region once follow has
# rebuilt it as a replica, and returns non-zero when it could not check or
# undo the drain. A replica answers 503, so being back in the pool
# takes no traffic; it is what lets the group fail back to it later.
restore_this_region() {
  echo
  echo "==> Putting this region back in the front door"
  local this old new dial
  if ! this="$(this_member)"; then
    echo "warning: if failover.sh promote drained this region, remove its entries from" >&2
    echo "         failover.auto.tfvars.json in the front door's directory and run" >&2
    echo "         'make group-apply' there." >&2
    return 1
  fi

  old="$(read_overrides)"
  new="$(jq -c --arg m "$this" \
    'del(.["\($m)_traffic_dial_percentage"], .["\($m)_gateway_lb_arn"])' <<<"$old")"
  if [[ "$new" != "$old" ]]; then
    echo "    Removing the ${this}'s drain from ${OVERRIDES}."
    if ! apply_group_overrides "$new" "Put the ${this} back in the front door? Type yes to continue:"; then
      echo "warning: the ${this} is still drained by ${OVERRIDES}. Remove its" >&2
      echo "         entries there and run 'make group-apply'." >&2
      return 1
    fi
  fi

  # A drain set by hand, before a planned failover, is in terraform.tfvars and
  # is not this script's to undo.
  dial="$(terraform -chdir="$GROUP_DIR" output -json traffic_dial_percentages 2>/dev/null |
    jq -r --arg m "$this" '.[$m] // empty' || true)"
  if [[ "$dial" == "0" ]]; then
    echo "note: the ${this} is still drained: ${GROUP_DIR}/terraform.tfvars sets"
    echo "      ${this}_traffic_dial_percentage = 0. Set it back to 100 and run"
    echo "      'make group-apply'; the group cannot fail back to it while it is drained."
  else
    echo "    The ${this} is in the front door."
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

  drain_old_writer

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

  # The rebuild is done either way. A region left drained takes no traffic
  # after a later failback to it, so that must not end in a zero exit.
  if ! restore_this_region; then
    echo "error: the databases were rebuilt, but this region may still be drained in" >&2
    echo "       the front door. Do what the warning above says before relying on it." >&2
    exit 1
  fi
}

# ---- main ------------------------------------------------------------------
if [[ "$COMMAND" == "status" ]]; then
  cmd_status
  exit 0
fi

PLAN_FILE="$(mktemp -t catalyst-failover-plan.XXXXXX)"
GROUP_PLAN_FILE="$(mktemp -t catalyst-failover-group-plan.XXXXXX)"
trap 'rm -f "$PLAN_FILE" "$GROUP_PLAN_FILE"' EXIT

case "$COMMAND" in
  promote) cmd_promote ;;
  follow) cmd_follow ;;
esac
