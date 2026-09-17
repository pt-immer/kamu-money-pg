# Extra trust anchors for the container build

Drop `.crt` files here (PEM, one certificate per file) and the image will trust them. An empty
directory is the normal case and costs nothing — `update-ca-certificates` ignores everything that
is not a `.crt`, so this README does not become a trust anchor.

**The certificates are gitignored on purpose.** An interception CA's subject line usually carries
an account or tenant identifier, and that is an org-identifying string. The mechanism belongs in
the repository; the certificate belongs on the machine that needs it.

## When you need this

The build fetches the PostgreSQL signing key over HTTPS. On a network that terminates and re-signs
TLS — a corporate proxy, a Zero Trust agent, an inspecting firewall — the container sees a
certificate chain your host trusts and it does not:

```text
curl: (60) SSL certificate problem: self-signed certificate in certificate chain
```

The host works and the container fails, which is the signature of this problem rather than a
network outage. Note the failure surfaces mid-`RUN`, after several packages have already installed,
so read the error rather than the exit status.

## Extracting the anchor

This asks the server for its chain and keeps the last certificate, which on an inspected connection
is the interceptor's root:

```sh
echo | openssl s_client -connect www.postgresql.org:443 -showcerts 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/{n++} END{}; n>=2' > kamu-money-pg/ca-certs/inspection-ca.crt
```

Verify it is a self-signed CA before trusting it — if subject and issuer differ, you captured an
intermediate and need its parent as well:

```sh
openssl x509 -in kamu-money-pg/ca-certs/inspection-ca.crt -noout -subject -issuer
openssl x509 -in kamu-money-pg/ca-certs/inspection-ca.crt -noout -text | grep -A1 'Basic Constraints'
```

Read what you extracted before you install it. This directory tells the build to trust a certificate
authority, and a certificate you have not inspected is one you cannot vouch for. The mechanism is
deliberately manual for that reason: nothing here fetches or installs an anchor on your behalf.

## Alternatives

Turning the inspecting agent off for the duration of the build works too, and leaves nothing on
disk. CI runners are typically uninspected, so this directory stays empty there and the image is
byte-identical either way.
