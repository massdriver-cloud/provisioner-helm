# This Dockerfile is intended to be built from the top of the repo (not this directory)
ARG XO_VERSION=latest
ARG HELM_VERSION=3.15.4
ARG CHECKOV_VERSION=3.2.268
ARG OPA_VERSION=0.69.0
ARG RUN_IMG=debian:12.7-slim
ARG USER=massdriver
ARG UID=10001

FROM 005022811284.dkr.ecr.us-west-2.amazonaws.com/massdriver-cloud/xo:${XO_VERSION} AS xo

FROM ${RUN_IMG} AS build
ARG HELM_VERSION
ARG CHECKOV_VERSION
ARG OPA_VERSION

ENV DEBIAN_FRONTEND=noninteractive
RUN apt update && apt install -y curl unzip make && \
    rm -rf /var/lib/apt/lists/* && \
    curl -sSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz > helm.tar.gz && tar -xzf helm.tar.gz -C /usr/local/bin && \
    curl -sSL https://openpolicyagent.org/downloads/v${OPA_VERSION}/opa_linux_amd64_static > /usr/local/bin/opa && chmod a+x /usr/local/bin/opa && \
    curl -sSL https://github.com/bridgecrewio/checkov/releases/download/${CHECKOV_VERSION}/checkov_linux_X86_64.zip > checkov.zip && unzip checkov.zip && mv dist/checkov /usr/local/bin/ && rm *.zip && \
    curl -sSL https://github.com/mikefarah/yq/releases/download/v4.40.5/yq_linux_amd64 > /usr/local/bin/yq && chmod a+x /usr/local/bin/yq

COPY --from=xo /usr/bin/xo /usr/local/bin/xo

FROM ${RUN_IMG}
ARG USER
ARG UID

RUN apt update && apt install -y ca-certificates jq && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 777 /massdriver

RUN adduser \
    --disabled-password \
    --gecos "" \
    --uid $UID \
    $USER
RUN chown -R $USER:$USER /massdriver
USER $USER

COPY --from=build /usr/local/bin/* /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/

ENV MASSDRIVER_PROVISIONER=helm

WORKDIR /massdriver

ENTRYPOINT ["entrypoint.sh"]