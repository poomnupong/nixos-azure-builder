#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap-azure-ci.sh — one-time Azure setup for nixos-azimage-builder CI.
#
# Creates:
#   * a *control* resource group (perpetual, holds shared state such as
#     storage account for the staging VHD and, optionally, the budget)
#   * N *run* resource groups (perpetual containers — RBAC lives here)
#   * a service principal used by GitHub Actions (federated credentials,
#     OIDC — no client secrets in the repo)
#   * Contributor role assignments for that SP scoped to each run RG and
#     (read-only) to the control RG
#   * an Azure budget on the subscription with an email action group
#
# Run this ONCE, locally, as a user with Owner on the subscription. Do not
# run it in CI — CI's service principal must not be able to grant itself
# new permissions.
#
# Usage:
#   ./scripts/bootstrap-azure-ci.sh \
#       --subscription <sub-id> \
#       --location southeastasia \
#       --github-repo poomnupong/nixos-azimage-builder \
#       --budget-email you@example.com \
#       [--run-rg-count 2] \
#       [--control-rg rg-nixos-ci-control] \
#       [--run-rg-prefix rg-nixos-ci-run] \
#       [--sp-name sp-nixos-azimage-builder-ci] \
#       [--budget-amount 10]
#
# The script is idempotent — re-running it is safe and will reconcile
# existing resources rather than duplicate them.
# ---------------------------------------------------------------------------
set -euo pipefail

SUBSCRIPTION=""
LOCATION=""
GITHUB_REPO=""
BUDGET_EMAIL=""
RUN_RG_COUNT=2
CONTROL_RG="rg-nixos-ci-control"
RUN_RG_PREFIX="rg-nixos-ci-run"
SP_NAME="sp-nixos-azimage-builder-ci"
BUDGET_AMOUNT=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)    SUBSCRIPTION="$2"; shift 2 ;;
    --location)        LOCATION="$2"; shift 2 ;;
    --github-repo)     GITHUB_REPO="$2"; shift 2 ;;
    --budget-email)    BUDGET_EMAIL="$2"; shift 2 ;;
    --run-rg-count)    RUN_RG_COUNT="$2"; shift 2 ;;
    --control-rg)      CONTROL_RG="$2"; shift 2 ;;
    --run-rg-prefix)   RUN_RG_PREFIX="$2"; shift 2 ;;
    --sp-name)         SP_NAME="$2"; shift 2 ;;
    --budget-amount)   BUDGET_AMOUNT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

for v in SUBSCRIPTION LOCATION GITHUB_REPO BUDGET_EMAIL; do
  if [[ -z "${!v}" ]]; then
    echo "ERROR: --${v,,} is required" >&2
    exit 2
  fi
done

echo "==> Using subscription $SUBSCRIPTION"
az account set --subscription "$SUBSCRIPTION"

# ---------------------------------------------------------------------------
# 1. Resource groups — control + run pool
# ---------------------------------------------------------------------------
echo "==> Ensuring control RG '$CONTROL_RG' in $LOCATION"
az group create -n "$CONTROL_RG" -l "$LOCATION" --tags purpose=nixos-ci role=control >/dev/null

RUN_RGS=()
for i in $(seq 1 "$RUN_RG_COUNT"); do
  rg="${RUN_RG_PREFIX}-$(printf '%02d' "$i")"
  RUN_RGS+=("$rg")
  echo "==> Ensuring run RG '$rg' in $LOCATION"
  az group create -n "$rg" -l "$LOCATION" --tags purpose=nixos-ci role=run >/dev/null
done

# ---------------------------------------------------------------------------
# 2. Service principal (no secret — we'll wire OIDC federation)
# ---------------------------------------------------------------------------
echo "==> Ensuring service principal '$SP_NAME'"
APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv || true)
if [[ -z "${APP_ID:-}" ]]; then
  APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
fi
SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv || true)
if [[ -z "${SP_OBJECT_ID:-}" ]]; then
  SP_OBJECT_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)
fi
TENANT_ID=$(az account show --query tenantId -o tsv)

# Federated credentials for GitHub OIDC — one per (workflow, ref) pair we use.
# See: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-azure
ensure_federated_credential() {
  local name="$1" subject="$2"
  local existing
  existing=$(az ad app federated-credential list --id "$APP_ID" \
    --query "[?name=='$name'] | [0].name" -o tsv || true)
  if [[ -z "$existing" ]]; then
    az ad app federated-credential create --id "$APP_ID" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
  fi
}
ensure_federated_credential "gh-main"       "repo:${GITHUB_REPO}:ref:refs/heads/main"
ensure_federated_credential "gh-janitor"    "repo:${GITHUB_REPO}:environment:azure-janitor"

# ---------------------------------------------------------------------------
# 3. RBAC — Contributor on each run RG, Reader on control RG.
#    Role assignments live under the RG scope; they survive teardown
#    *only* if the RG itself is not deleted (which is why we empty it
#    with a complete-mode deployment, not `az group delete`).
# ---------------------------------------------------------------------------
echo "==> Granting RBAC to SP (object id $SP_OBJECT_ID)"
for rg in "${RUN_RGS[@]}"; do
  scope="/subscriptions/$SUBSCRIPTION/resourceGroups/$rg"
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "Contributor" --scope "$scope" >/dev/null || true
done
az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Reader" \
  --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/$CONTROL_RG" >/dev/null || true

# ---------------------------------------------------------------------------
# 4. Budget alert — Layer-4 backstop: if everything else leaks, this emails.
# ---------------------------------------------------------------------------
echo "==> Ensuring subscription budget 'nixos-ci-budget' ($BUDGET_AMOUNT USD/month)"
START_DATE=$(date -u +%Y-%m-01)
az consumption budget create \
  --budget-name "nixos-ci-budget" \
  --amount "$BUDGET_AMOUNT" \
  --category cost \
  --time-grain Monthly \
  --start-date "$START_DATE" \
  --end-date "2099-12-31" \
  --notifications "[{
      \"enabled\": true,
      \"operator\": \"GreaterThan\",
      \"threshold\": 80,
      \"contactEmails\": [\"$BUDGET_EMAIL\"],
      \"notificationLanguage\": \"en-us\"
    }]" >/dev/null 2>&1 || \
  echo "   (budget may already exist or require elevated permissions — skipping)"

# ---------------------------------------------------------------------------
# 5. Emit the GitHub Actions variables / secrets the workflows expect.
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
Bootstrap complete. Configure these in GitHub repo settings:

  Secrets (Settings → Secrets and variables → Actions → Secrets):
    AZURE_CLIENT_ID       = $APP_ID
    AZURE_TENANT_ID       = $TENANT_ID
    AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION

  Variables (Settings → Secrets and variables → Actions → Variables):
    AZURE_LOCATION        = $LOCATION
    AZURE_CONTROL_RG      = $CONTROL_RG
    AZURE_RUN_RGS         = ${RUN_RGS[*]}

Also create an Actions environment named 'azure-janitor' (used by the
janitor workflow's federated credential subject).
============================================================================
EOF
