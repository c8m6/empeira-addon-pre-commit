# Appended to the default or repository's Containerfile.pre-commit.
# SPDX-License-Identifier: AGPL-3.0-only
USER root
ARG PRE_COMMIT_VERSION
RUN python -m pip install --no-cache-dir "pre-commit==${PRE_COMMIT_VERSION}"
ENV PRE_COMMIT_HOME=/opt/pre-commit HOME=/tmp/empeira-home
COPY .pre-commit-config.yaml /build-repo/.pre-commit-config.yaml
COPY run.py /opt/empeira/run.py
WORKDIR /build-repo
RUN git init -q && pre-commit validate-config && pre-commit install-hooks \
    && python /opt/empeira/run.py --check \
    && chmod -R a+rwX /opt/pre-commit && chmod 0644 /opt/empeira/run.py \
    && rm -rf /build-repo /tmp/empeira-home
ENTRYPOINT ["python", "/opt/empeira/run.py"]
CMD ["run"]
