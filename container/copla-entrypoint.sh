#!/usr/bin/env bash
#
# Container wrapper for bin/copla.py
#
# COPLA's scripts use paths relative to the install directory (bin/, databases/),
# so they must run from ${COPLA_HOME}. This wrapper turns the user's input/output
# paths into absolute paths, supplies the bundled reference database, and then
# runs copla.py from ${COPLA_HOME}.
#
# Usage: copla QUERY.fna OUTDIR [copla.py options]
#        copla post-install-test   # run COPLA's own installation test
#        copla shell               # interactive shell inside the container

set -euo pipefail

COPLA_HOME=${COPLA_HOME:-/opt/copla}
COPLA_DB_DIR=${COPLA_HOME}/$(grep '^COPLA_DB_DIR' "${COPLA_HOME}/copla.ini" | cut -f2)

usage() {
    cat <<EOF
Usage: copla QUERY.fna OUTDIR [options]

Predict the PTU of a plasmid using the bundled RefSeq84 database.
QUERY.fna and OUTDIR are resolved relative to the current directory.

Options (passed to copla.py):
  -a, --aminoacid FILE   aminoacid sequence (ORFeome) of the query
  -t, --topology STR     circular (default) or linear
  -k/-p/-c/-o/-f/-g/-s   host taxonomy: kingdom/phylum/class/order/family/genus/species

Other commands:
  copla post-install-test   run COPLA's post-installation test
  copla shell               start a shell inside the container
EOF
}

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "${PWD}/$1" ;;
    esac
}

case "${1:-}" in
    ''|-h|--help)
        usage
        exit 0
        ;;
    post-install-test)
        # The test writes its outputs into test/, so run it on a writable copy
        # (the image is read-only under Apptainer)
        WORK=$(mktemp -d)
        cp -r "${COPLA_HOME}/test" "${WORK}/"
        for f in bin copla.ini databases; do ln -s "${COPLA_HOME}/${f}" "${WORK}/${f}"; done
        cd "${WORK}"
        exec bin/post_install_test.sh
        ;;
    shell)
        shift
        exec bash "$@"
        ;;
esac

positional=()
options=()
while [ $# -gt 0 ]; do
    case "$1" in
        -a|--aminoacid)
            options+=("$1" "$(abspath "$2")")
            shift 2
            ;;
        -t|--topology|-k|--taxKingdom|-p|--taxPhylum|-c|--taxClass|-o|--taxOrder|-f|--taxFamily|-g|--taxGenus|-s|--taxSpecies)
            options+=("$1" "$2")
            shift 2
            ;;
        --version)
            options+=("$1")
            shift
            ;;
        -*)
            echo "copla: unknown option $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            positional+=("$(abspath "$1")")
            shift
            ;;
    esac
done

if [ "${options[*]:-}" != "--version" ] && [ ${#positional[@]} -ne 2 ]; then
    usage >&2
    exit 2
fi

cd "${COPLA_HOME}"
exec bin/copla.py \
    "${positional[0]:-}" \
    "${COPLA_DB_DIR}/RS84f_sHSBM.pickle" \
    "${COPLA_DB_DIR}/CoplaDB.fofn" \
    "${positional[1]:-}" \
    ${options[@]+"${options[@]}"}
