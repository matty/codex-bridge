# routes.sh — the one place that decides which Codex model and reasoning effort
# each kind of task runs on. Sourced by bin/codex-run and bin/codex-imagegen.
#
# Edit the table to re-route. -m / -e on the command line always win over a route.
# Valid efforts: low | medium | high | xhigh | max | ultra (ultra lets Codex spawn
# its own subagents, so no route uses it by default).
#
# route_lookup <route> — prints "<model> <effort>", or exits 1 for an unknown route.
route_lookup() {
  case "$1" in
    quick)     echo "gpt-6-luna medium" ;;     # one-off questions, lookups
    review)    echo "gpt-6.1-sol high" ;;      # code review of a diff or module
    implement) echo "gpt-6.1-terra medium" ;;  # bulk edits; 500k context
    debug)     echo "gpt-6-astra xhigh" ;;     # root-causing failures
    opinion)   echo "gpt-6-astra high" ;;      # design calls, second opinions
    image)     echo "gpt-6-luna low" ;;        # only drives gpt-image-2
    *)         return 1 ;;
  esac
}

ROUTE_NAMES="quick review implement debug opinion image"
EFFORTS="low medium high xhigh max ultra"

valid_effort() {
  case " $EFFORTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Never the Fast / priority tier: it costs extra plan usage. Pinned on every call
# so a change to ~/.codex/config.toml can't switch it on behind our back.
SERVICE_TIER_ARGS=(-c 'service_tier="default"')
