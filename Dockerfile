# COPLA container image
#
# Build (on Apple Silicon this runs under amd64 emulation, which is what the
# pinned linux-64 conda spec files and the HPC require):
#   docker build --platform linux/amd64 -t copla:latest .
#
# Run:
#   docker run --rm --platform linux/amd64 -v "$PWD":/data -w /data copla:latest \
#       query.fna query_output [copla.py options]

FROM --platform=linux/amd64 condaforge/miniforge3:25.3.1-0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV COPLA_HOME=/opt/copla \
    CONDA_EXE=/opt/conda/bin/conda \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# System X11/GL libraries expected by the 2020-era gtk3 package (pulled in by
# graph-tool), whose post-link script fails without them; procps for parallel
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libx11-6 libxext6 libxrender1 libxi6 libxtst6 libxrandr2 libxfixes3 \
        libxcursor1 libxdamage1 libxcomposite1 libxinerama1 libgl1 procps \
 && rm -rf /var/lib/apt/lists/*

# Conda environments, built from the exact package lists used to develop COPLA
COPY copla.spec-file.txt macsyfinder.spec-file.txt /tmp/
RUN conda create -y -q -n copla --file /tmp/copla.spec-file.txt \
 && conda create -y -q -n macsyfinder --file /tmp/macsyfinder.spec-file.txt \
 && conda clean -afy \
 && rm /tmp/*.spec-file.txt

# MacSyFinder 1.0.5 (Python 2) installed into its own environment
ARG MACSYFINDER_VERSION=1.0.5
ARG MACSYVIEW_VERSION=1.0.1
RUN cd /opt/conda/envs/macsyfinder \
 && wget -q https://github.com/gem-pasteur/macsyfinder/archive/macsyfinder-${MACSYFINDER_VERSION}.tar.gz \
 && wget -q https://github.com/gem-pasteur/macsyview/archive/macsyview-${MACSYVIEW_VERSION}.tar.gz \
 && tar zxf macsyfinder-${MACSYFINDER_VERSION}.tar.gz \
 && tar zxf macsyview-${MACSYVIEW_VERSION}.tar.gz \
 && mv macsyfinder-macsyfinder-${MACSYFINDER_VERSION} src \
 && mv macsyview-macsyview-${MACSYVIEW_VERSION} src/macsyview \
 && cd src \
 && /opt/conda/envs/macsyfinder/bin/python setup.py build \
 && /opt/conda/envs/macsyfinder/bin/python setup.py install --prefix=/opt/conda/envs/macsyfinder \
 && cd .. && rm -rf src *.tar.gz \
 && /opt/conda/envs/macsyfinder/bin/macsyfinder --version

# COPLA scripts
WORKDIR ${COPLA_HOME}
COPY copla.ini ./
COPY bin/ bin/
COPY test/ test/

# ani.rb from the Enveomics collection, pinned to a fixed commit
ARG ENVEOMICS_COMMIT=8660352c0b91e553a4252cbfb54083e75e37e3f3
RUN wget -q -O bin/ani.rb https://raw.githubusercontent.com/lmrodriguezr/enveomics/${ENVEOMICS_COMMIT}/Scripts/ani.rb \
 && chmod +x bin/*

# COPLA databases (~350 MB tar). CoplaDB.fofn gets absolute paths under ${COPLA_HOME}
RUN bin/download_Copla_databases.sh \
 && rm Copla_databases_latest.tar \
 && head -n 2 databases/Copla_RS84/CoplaDB.fofn

# The copla env is the default; check_conjugation_systems.sh switches to the
# macsyfinder env itself via conda.sh
ENV PATH=/opt/conda/envs/copla/bin:/opt/conda/bin:${PATH}

# Silence GNU parallel's citation notice
RUN mkdir -p /root/.parallel && touch /root/.parallel/will-cite

COPY container/copla-entrypoint.sh /usr/local/bin/copla
RUN chmod +x /usr/local/bin/copla

ENTRYPOINT ["/usr/local/bin/copla"]
CMD ["--help"]
