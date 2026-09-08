# Dependabot's docker ecosystem rewrites this line, tag and digest together. vet-action
# resolves its binary from the latest GitHub release at run time and takes its version
# through `with:`, so neither the action nor a github-actions update can be the pin.
FROM ghcr.io/safedep/vet:v1.19.0@sha256:6832b2780cd8633d171d0c37500e6fb182ef57c5f553984b34c680845a5eac55

COPY scripts/run-vet.sh /run-vet.sh

# The upstream entrypoint is `vet` itself; the wrapper assembles the filter suite.
ENTRYPOINT ["/run-vet.sh"]
