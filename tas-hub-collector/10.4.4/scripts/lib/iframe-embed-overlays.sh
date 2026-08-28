#!/usr/bin/env bash
#
# iframe-embed-overlays.sh
#
# Makes Tanzu Hub embeddable in a cross-site iframe (Educates workshops).
#
#   1. contour ConfigMap   -> remove x-frame-options
#   2. tanzu-sm-httpproxy  -> SameSite=None; Secure on the UAA login cookies
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
# Run AFTER a Tanzu SM install completes, on every build. Idempotent.
#
set -euo pipefail

NS="${NS:-tanzusm}"
PARENT_PKGI="${PARENT_PKGI:-sm}"
HUB_FQDN="${HUB_FQDN:-}"

# Annotation indices. Vendor uses 0,2-8,10,17 on child pkgis and none on 'sm'.
IDX_PARENT=30    # on the 'sm' pkgi
IDX_COOKIE=30    # on contour-httpproxy
IDX_FRAME=31     # on contour

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# -- level 3: cookie SameSite on the HTTPProxy --------------------------------
cat > "$WORK/uaa-cookie-samesite.yaml" <<'EOF'
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
cat > "$WORK/contour-frame-headers.yaml" <<'EOF'
#@ load("@ytt:overlay", "overlay")
#@ load("@ytt:yaml", "yaml")

#@ def with_frame_policy(existing):
#@   cfg = yaml.decode(existing)
#@   policy = cfg.get("policy", {})
#@   headers = policy.get("response-headers", {})
#@   headers["remove"] = ["x-frame-options"]
#@   policy["response-headers"] = headers
#@   policy["applyToIngress"] = True
#@   cfg["policy"] = policy
#@   return yaml.encode(cfg)
#@ end

---
#@overlay/match by=overlay.subset({"kind": "ConfigMap", "metadata": {"name": "contour"}}), expects="0+"
---
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

echo "==> ensuring the cascade is live"
kubectl -n "$NS" patch pkgi "$PARENT_PKGI" --type=merge -p '{"spec":{"paused":false}}'
kctrl package installed kick -i "$PARENT_PKGI" -n "$NS" -y

echo "==> waiting for the child pkgis to pick up the annotation"
for i in $(seq 1 60); do
  got=$(kubectl -n "$NS" get pkgi contour-httpproxy \
    -o "jsonpath={.metadata.annotations.ext\.packaging\.carvel\.dev/ytt-paths-from-secret-name\.${IDX_COOKIE}}" 2>/dev/null || true)
  [[ -n "$got" ]] && { echo "    child annotated after ${i}0s"; break; }
  sleep 10
done

# -- verify -------------------------------------------------------------------
echo "==> rendered HTTPProxy routes under /auth"
kubectl -n "$NS" get httpproxy tanzu-sm-httpproxy \
  -o jsonpath='{range .spec.routes[*]}{@.conditions[0]}{" -> "}{@.cookieRewritePolicies[*].name}{"\n"}{end}' \
  | grep -i auth || echo "    (no cookieRewritePolicies yet - child may still be reconciling)"

echo "==> rendered contour.yaml policy block"
kubectl -n "$NS" get cm contour -o jsonpath='{.data.contour\.yaml}' | grep -A4 'response-headers' || true

if [[ -n "$HUB_FQDN" ]]; then
  echo "==> live check against $HUB_FQDN"
  echo "--- cookies (want SameSite=None; Secure) ---"
  curl -sSI "https://${HUB_FQDN}/auth/login" | grep -i '^set-cookie' || true
  echo "--- x-frame-options (want absent) ---"
  curl -sSI "https://${HUB_FQDN}/hub/" | grep -i '^x-frame-options' || echo "    (absent - good)"
else
  echo "==> set HUB_FQDN=hub.<env>.cf-app.com to run the live check"
fi
