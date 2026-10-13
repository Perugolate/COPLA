#!/bin/bash
#SBATCH --chdir=/mnt/shared/scratch/pjohnsto/COPLA/
#SBATCH --job-name=test_copla_image
#SBATCH --export=ALL
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=8G
#SBATCH --time=02:00:00
#SBATCH --partition=short
#
# Test a built copla.sif. Run from the COPLA repository root:
#   sbatch container/test_copla_sif.sh [path/to/copla.sif]
#
# 1. Smoke tests: the wrapper's help text and the image's %test section
# 2. COPLA's own post-install test (stdout of both test plasmids vs expected)
# 3. A normal user-style run from a separate directory with relative paths,
#    comparing the result files against the expected outputs in test/*.tgz
#
# Exits non-zero if any check fails; a summary is printed at the end.

source /home/${USER}/.bashrc

set -uo pipefail

SIF=$(realpath "${1:-copla.sif}")
REPO=${PWD}
THREADS=${SLURM_CPUS_PER_TASK:-4}
WORK=${REPO}/copla_sif_test_${SLURM_JOB_ID:-$$}
mkdir -p "${WORK}"

# GNU parallel reads default options from $PARALLEL, which caps the ANI step at
# the allocated CPUs (otherwise it starts one job per core on the whole node).
# hmmscan (--cpu 9) and MacSyFinder (-w 20) are still hardcoded in COPLA, but
# they only run briefly.
export APPTAINERENV_PARALLEL="-j ${THREADS}"

# Use the job's temporary directory for /tmp inside the container if there is one
APPTAINER_OPTS=(--cleanenv --bind "${REPO}" --bind "${TMPDIR:-/tmp}:/tmp")
copla() { apptainer run "${APPTAINER_OPTS[@]}" "${SIF}" "$@"; }

FAILURES=()
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES+=("$1"); }

echo "Image:   ${SIF}"
echo "Work:    ${WORK}"
echo "Threads: ${THREADS}"
echo "Host:    $(hostname)"
apptainer --version
echo

# --- 1. Smoke tests ---------------------------------------------------------
echo "=== 1. Smoke tests"
if copla --help > "${WORK}/help.log" 2>&1; then
    pass "wrapper --help"
else
    fail "wrapper --help (see ${WORK}/help.log)"
fi
if apptainer test "${APPTAINER_OPTS[@]}" "${SIF}" > "${WORK}/apptainer_test.log" 2>&1; then
    pass "apptainer test (%test section)"
else
    fail "apptainer test (see ${WORK}/apptainer_test.log)"
fi
echo

# --- 2. COPLA post-install test ---------------------------------------------
echo "=== 2. COPLA post-install test"
start=${SECONDS}
copla post-install-test 2>&1 | tee "${WORK}/post_install_test.log"
echo "(took $(( (SECONDS - start) / 60 )) min)"
if grep -qE 'Error!|Warning!' "${WORK}/post_install_test.log"; then
    fail "post-install test reported errors or warnings"
fi
for acc in NZ_CP028167.1 NZ_CP028329.1; do
    if grep -q "OK - Output for plasmid ${acc} is as expected" "${WORK}/post_install_test.log"; then
        pass "post-install test output for ${acc}"
    else
        fail "post-install test output for ${acc}"
    fi
done
echo

# --- 3. User-style run, compared against the expected result files ----------
echo "=== 3. User-style run with relative paths from a separate directory"
ACC=NZ_CP028167.1
RUN=${WORK}/user_run
EXPECTED=${WORK}/expected
mkdir -p "${RUN}/input" "${EXPECTED}"
cp "${REPO}/test/${ACC}.fna" "${REPO}/test/${ACC}.faa" "${RUN}/input/"
tar -xzf "${REPO}/test/${ACC}.tgz" -C "${EXPECTED}"

start=${SECONDS}
(
    cd "${RUN}" && copla "input/${ACC}.fna" out -a "input/${ACC}.faa" -t circular \
        -k Bacteria -p Proteobacteria -c Gammaproteobacteria -o Enterobacterales \
        -f Enterobacteriaceae -g Escherichia -s 'Escherichia coli'
) > "${RUN}/stdout.log" 2>&1
echo "(took $(( (SECONDS - start) / 60 )) min)"

if diff -q "${REPO}/test/${ACC}.fna_stdout" "${RUN}/stdout.log" > /dev/null; then
    pass "user run stdout"
else
    fail "user run stdout (diff ${REPO}/test/${ACC}.fna_stdout ${RUN}/stdout.log)"
fi

# Result files. The ANI table starts with the query path and its row order
# depends on directory listing order, so compare it without column 1, sorted.
compare() {
    local name=$1 got=$2 exp=$3 mode=$4
    if [ ! -s "${got}" ]; then
        fail "${name}: missing or empty ${got}"
        return
    fi
    case ${mode} in
        exact)  diff -q "${exp}" "${got}" > /dev/null ;;
        sorted) diff -q <(sort "${exp}") <(sort "${got}") > /dev/null ;;
        ani)    diff -q <(cut -f2- "${exp}" | sort) <(cut -f2- "${got}" | sort) > /dev/null ;;
    esac && pass "${name}" || fail "${name} differs from expected"
}
EXP_DIR=${EXPECTED}/${ACC}.fna_output
GOT_DIR=${RUN}/out
compare "ptu_prediction.tsv"   "${GOT_DIR}/${ACC}.fna.ptu_prediction.tsv"   "${EXP_DIR}/${ACC}.fna.ptu_prediction.tsv"   exact
compare "qry_info.tsv"         "${GOT_DIR}/${ACC}.fna.qry_info.tsv"         "${EXP_DIR}/${ACC}.fna.qry_info.tsv"         exact
compare "related_plasmids.tsv" "${GOT_DIR}/${ACC}.fna.related_plasmids.tsv" "${EXP_DIR}/${ACC}.fna.related_plasmids.tsv" sorted
compare "ani.tsv"              "${GOT_DIR}/${ACC}.fna.ani.tsv"              "${EXP_DIR}/${ACC}.fna.ani.tsv"              ani
echo

# --- Summary ----------------------------------------------------------------
echo "=== Summary"
if [ ${#FAILURES[@]} -eq 0 ]; then
    echo "All checks passed. Logs and outputs are in ${WORK}"
    exit 0
else
    echo "${#FAILURES[@]} check(s) failed:"
    printf '  - %s\n' "${FAILURES[@]}"
    echo "Logs and outputs are in ${WORK}"
    exit 1
fi
