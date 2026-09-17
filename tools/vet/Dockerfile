# Dependabot updates the tag and digest together.
FROM ghcr.io/safedep/vet:v1.19.1@sha256:5f36dc05ae3c0a9eb09f466436bc3bff369db776e771f579faed983bcfcc2f95

COPY scripts/run-vet.sh /run-vet.sh

ENTRYPOINT ["/run-vet.sh"]
