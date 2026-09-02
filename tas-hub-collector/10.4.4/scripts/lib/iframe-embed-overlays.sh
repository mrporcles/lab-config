#!/usr/bin/env bash
#
# iframe-embed-overlays.sh
#
# Makes Tanzu Hub embeddable in a cross-site iframe (Educates workshops).
#
#   1. contour ConfigMap   -> remove x-frame-options / x-xss-protection
#   2. tanzu-sm-httpproxy  -> SameSite=None; Secure on the UAA login cookies
#   3. both                -> CSP frame-ancestors limiting who may frame Hub
#
# Tanzu SM is a three-level kapp hierarchy:
#
#   sm.tanzu.broadcom.com (installer, one-shot)  ->  'sm' PackageInstall
#   sm.app                                       ->  29 child PackageInstalls
#   contour.app / contour-httpproxy.app          ->  ConfigMap / HTTPProxy
#
# Anything written to level 2 or 3 by hand is reverted the next time the level
# above reconciles - observed in the wild within ~40 minutes. So this installs
# at level 1: 'sm' gets an overlay that stamps ytt-paths annotations onto the
# two child pkgis, which then apply the real overlays to their own output.
#
# Contour reads contour.yaml only at startup (no file watcher), so the overlay marks
# that ConfigMap kapp.k14s.io/versioned. kapp then renames it per revision and
# rewrites the Deployment reference, rolling Contour automatically on any change -
# self-healing, no imperative restart.
#
# Requires kubectl and curl only - no kctrl, no ytt on the runner.
#
# Run AFTER a Tanzu SM install completes, on every build. Idempotent.
#
set -euo pipefail

NS="${NS:-tanzusm}"
PARENT_PKGI="${PARENT_PKGI:-sm}"
HUB_FQDN="${HUB_FQDN:-}"
CONTOUR_DEPLOY="${CONTOUR_DEPLOY:-contour}"

# Origins permitted to frame Hub. Space-separated CSP host-sources; CSP wildcards
# match nested subdomains, so one entry covers every workshop session hostname.
# frame-ancestors validates EVERY ancestor in the chain, not just the immediate
# parent. The Broadcom academy portal frames the Educates workshop, which frames
# Hub - so the portal origin must be listed alongside the Educates hosts.
FRAME_ANCESTORS="${FRAME_ANCESTORS:-'self' https://tanzu.academy *.tanzu.academy https://tanzu-staging.academy *.tanzu-staging.academy *.cf-app.com *.broadcom.com *.vmware.com}"
CSP_GLOBAL="frame-ancestors ${FRAME_ANCESTORS}"
# UAA sets its own "script-src 'self'" on /auth. Contour's `set` REPLACES rather
# than merges, so the per-route value must restate script-src or UAA silently
# loses it. Per-route wins over the global default (internal/dag/policy.go).
CSP_AUTH="script-src 'self'; ${CSP_GLOBAL}"

# Annotation indices. Vendor uses 0,2-8,10,17 on child pkgis and none on 'sm'.
IDX_PARENT=30    # on the 'sm' pkgi
IDX_COOKIE=30    # on contour-httpproxy
IDX_FRAME=31     # on contour

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -- level 3: cookie SameSite on the HTTPProxy --------------------------------
cat > "$WORK/uaa-cookie-samesite.yaml" <<EOF
#@ load("@ytt:overlay", "overlay")
---
#@overlay/match by=overlay.subset({"kind": "HTTPProxy", "metadata": {"name": "tanzu-sm-httpproxy"}}), expects="0+"
---
spec:
  routes:
  #@overlay/append
  - conditions:
      - prefix: /auth
    services:
      - name: uaa
        port: 8080
        responseHeadersPolicy:
          set:
            - name: Content-Security-Policy
              value: "${CSP_AUTH}"
    timeoutPolicy:
      response: 60s
    cookieRewritePolicies:
      - name: X-Uaa-Csrf
        sameSite: "None"
        secure: true
      - name: JSESSIONID
        sameSite: "None"
        secure: true
EOF

# -- level 3: frame headers in the contour ConfigMap --------------------------
# Decodes the embedded contour.yaml, merges the policy block, re-encodes, so a
# package upgrade that adds new keys is not clobbered by a hardcoded blob.
cat > "$WORK/contour-frame-headers.yaml" <<EOF
#@ load("@ytt:overlay", "overlay")
#@ load("@ytt:yaml", "yaml")

#@ def with_frame_policy(existing):
#@   cfg = yaml.decode(existing)
#@   policy = cfg.get("policy", {})
#@   headers = policy.get("response-headers", {})
#@   headers["remove"] = ["x-frame-options"]
#@   sets = headers.get("set", {})
#@   sets["content-security-policy"] = "${CSP_GLOBAL}"
#@   headers["set"] = sets
#@   policy["response-headers"] = headers
#@   policy["applyToIngress"] = True
#@   cfg["policy"] = policy
#@   return yaml.encode(cfg)
#@ end

---
#@overlay/match by=overlay.subset({"kind": "ConfigMap", "metadata": {"name": "contour"}}), expects="0+"
---
metadata:
  #@overlay/match missing_ok=True
  annotations:
    #@overlay/match missing_ok=True
    kapp.k14s.io/versioned: ""
    #@overlay/match missing_ok=True
    kapp.k14s.io/num-versions: "5"
data:
  #@overlay/replace via=lambda left, right: with_frame_policy(left)
  contour.yaml: ""
EOF

# -- level 2: teach 'sm' to wire the two overlays onto its children -----------
# Mirrors the vendor's own add-nested-pkgi-annotations-overlay, but targeted.
cat > "$WORK/sm-nested-iframe.yaml" <<EOF
#@ load("@ytt:overlay", "overlay")

#@overlay/match by=overlay.subset({"kind": "PackageInstall", "metadata": {"name": "contour-httpproxy"}}), expects="0+"
---
metadata:
  #@overlay/match missing_ok=True
  annotations:
    #@overlay/match missing_ok=True
    ext.packaging.carvel.dev/ytt-paths-from-secret-name.${IDX_COOKIE}: uaa-cookie-samesite-overlay

#@overlay/match by=overlay.subset({"kind": "PackageInstall", "metadata": {"name": "contour"}}), expects="0+"
---
metadata:
  #@overlay/match missing_ok=True
  annotations:
    #@overlay/match missing_ok=True
    ext.packaging.carvel.dev/ytt-paths-from-secret-name.${IDX_FRAME}: contour-frame-headers-overlay
EOF

# -- install ------------------------------------------------------------------
apply_secret() {
  kubectl -n "$NS" create secret generic "$1" \
    --from-file="$(basename "$2")=$2" \
    --dry-run=client -o yaml | kubectl apply -f -
}

echo "==> creating overlay secrets in $NS"
apply_secret uaa-cookie-samesite-overlay   "$WORK/uaa-cookie-samesite.yaml"
apply_secret contour-frame-headers-overlay "$WORK/contour-frame-headers.yaml"
apply_secret sm-nested-iframe-overlay      "$WORK/sm-nested-iframe.yaml"

echo "==> wiring the overlay onto the '$PARENT_PKGI' PackageInstall"
kubectl -n "$NS" annotate pkgi "$PARENT_PKGI" --overwrite \
  "ext.packaging.carvel.dev/ytt-paths-from-secret-name.${IDX_PARENT}=sm-nested-iframe-overlay"

# Pure-kubectl equivalent of `kctrl package installed kick`, which is just
# pause -> wait for the App to report Canceled/paused -> unpause -> wait for
# reconciliation. Avoids needing kctrl in the image.
kick_pkgi() {
  local name="$1" desc
  echo "    pausing $name"
  kubectl -n "$NS" patch pkgi "$name" --type=merge -p '{"spec":{"paused":true}}' >/dev/null
  for _ in $(seq 1 60); do
    desc="$(kubectl -n "$NS" get app "$name" -o jsonpath='{.status.friendlyDescription}' 2>/dev/null || true)"
    [[ "$desc" == "Canceled/paused" ]] && break
    sleep 2
  done
  echo "    unpausing $name"
  kubectl -n "$NS" patch pkgi "$name" --type=merge -p '{"spec":{"paused":false}}' >/dev/null
  for _ in $(seq 1 120); do
    desc="$(kubectl -n "$NS" get app "$name" -o jsonpath='{.status.friendlyDescription}' 2>/dev/null || true)"
    case "$desc" in
      "Reconcile succeeded") echo "    $name reconciled"; return 0 ;;
      Reconcile\ failed*)    echo "    WARNING: $name reconcile failed: $desc"; return 0 ;;
    esac
    sleep 5
  done
  echo "    WARNING: timed out waiting for $name to reconcile (last: ${desc:-unknown})"
}

echo "==> kicking '$PARENT_PKGI' so the cascade re-renders"
kick_pkgi "$PARENT_PKGI"

echo "==> waiting for the child pkgis to pick up the annotation"
for i in $(seq 1 60); do
  got=$(kubectl -n "$NS" get pkgi contour-httpproxy \
    -o "jsonpath={.metadata.annotations.ext\.packaging\.carvel\.dev/ytt-paths-from-secret-name\.${IDX_COOKIE}}" 2>/dev/null || true)
  [[ -n "$got" ]] && { echo "    child annotated after ${i}0s"; break; }
  sleep 10
done

# The ConfigMap is annotated kapp.k14s.io/versioned, so kapp renders it as
# contour-ver-N and rewrites the Deployment's volume reference to match. Any
# change to the content produces a new N, which rolls the Contour pods on its
# own. That matters because Contour parses its config file ONCE at startup -
# there is no file watcher - so without versioning a ConfigMap edit is inert
# until something restarts the pod. No `rollout restart` needed here.
latest_cm() {
  kubectl -n "$NS" get cm -o name 2>/dev/null \
    | sed -n 's|^configmap/\(contour-ver-[0-9]\+\)$|\1|p' \
    | sort -t- -k3 -n | tail -1
}

echo "==> waiting for a versioned contour ConfigMap carrying the policy"
CM=""
for i in $(seq 1 30); do
  CM="$(latest_cm)"
  if [[ -n "$CM" ]] && kubectl -n "$NS" get cm "$CM" \
       -o jsonpath='{.data.contour\.yaml}' 2>/dev/null | grep -q 'x-frame-options'; then
    echo "    $CM carries the policy (after ${i}0s)"
    break
  fi
  sleep 10
done
if [[ -z "$CM" ]]; then
  echo "    WARNING: no contour-ver-* ConfigMap found."
  echo "    kapp may not be rewriting the Deployment reference - check that the"
  echo "    contour Deployment consumes the ConfigMap via a volume, not a literal name."
  CM=contour
fi

# The Contour deployment is not necessarily named "contour" - chart-derived
# names vary - so find whichever workload actually mounts the versioned
# ConfigMap instead of assuming.
detect_contour_deploy() {
  kubectl -n "$NS" get deploy --no-headers 2>/dev/null \
    -o custom-columns='NAME:.metadata.name,CM:.spec.template.spec.volumes[*].configMap.name' \
    | awk -v cm="$CM" '$2 ~ cm { print $1; exit }'
}

DEPLOY="$(detect_contour_deploy || true)"
if [[ -z "$DEPLOY" ]]; then DEPLOY="$CONTOUR_DEPLOY"; fi

if kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
  echo "==> waiting for $DEPLOY to roll onto $CM"
  kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=300s \
    || echo "    WARNING: rollout did not complete in time"
  echo "    $DEPLOY references: $(kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.volumes[*].configMap.name}')"
else
  echo "    WARNING: found no Deployment mounting $CM (tried '$DEPLOY')."
  echo "    Contour workloads and the ConfigMaps they mount:"
  kubectl -n "$NS" get deploy,ds,sts --no-headers 2>/dev/null \
    -o custom-columns='NAME:.metadata.name,CM:.spec.template.spec.volumes[*].configMap.name' \
    | grep -i contour || echo "    (none matched 'contour')"
fi

# -- verify -------------------------------------------------------------------
echo "==> rendered HTTPProxy routes under /auth"
kubectl -n "$NS" get httpproxy tanzu-sm-httpproxy \
  -o jsonpath='{range .spec.routes[*]}{@.conditions[0]}{" -> "}{@.cookieRewritePolicies[*].name}{"\n"}{end}' \
  | grep -i auth || echo "    (no cookieRewritePolicies yet - child may still be reconciling)"

echo "==> rendered contour.yaml policy block"
kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.contour\.yaml}' | grep -A4 'response-headers' || true

if [[ -n "$HUB_FQDN" ]]; then
  echo "==> live check against $HUB_FQDN"
  echo "--- cookies (want SameSite=None; Secure) ---"
  curl -sSI "https://${HUB_FQDN}/auth/login" | grep -i '^set-cookie' || true
  echo "--- x-frame-options (want absent) ---"
  curl -sSI "https://${HUB_FQDN}/hub/" | grep -i '^x-frame-options' || echo "    (absent - good)"
  echo "--- CSP on /hub/ (want frame-ancestors) ---"
  curl -sSI "https://${HUB_FQDN}/hub/" | grep -i '^content-security-policy' || echo "    MISSING"
  echo "--- CSP on /auth/login (want script-src AND frame-ancestors) ---"
  curl -sSI "https://${HUB_FQDN}/auth/login" | grep -i '^content-security-policy' || echo "    MISSING"
else
  echo "==> set HUB_FQDN=hub.<env>.cf-app.com to run the live check"
fi
