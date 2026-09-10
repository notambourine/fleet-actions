# Dependabot updates the tag and digest together.
FROM ghcr.io/safedep/vet:v1.19.0@sha256:6832b2780cd8633d171d0c37500e6fb182ef57c5f553984b34c680845a5eac55

COPY scripts/run-vet.sh /run-vet.sh

ENTRYPOINT ["/run-vet.sh"]
