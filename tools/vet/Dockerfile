# Dependabot updates the tag and digest together.
FROM ghcr.io/safedep/vet:v1.20.0@sha256:8679f183918e5d5a7c924310f34bc6f39324ac367e7dcbcfbc1b42e4e90431dd

COPY scripts/run-vet.sh /run-vet.sh

ENTRYPOINT ["/run-vet.sh"]
