# 負荷生成ツールのイメージ（ECS Fargate / ARM64 で動かす。手元の動作確認は amd64 でも可）
FROM public.ecr.aws/docker/library/ubuntu:24.04

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive

# sysbench: 負荷生成 / mysql-client: データ投入・確認 / sysstat: 負荷側 CPU の記録（mpstat）
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sysbench mysql-client sysstat gawk bsdextrautils jq curl unzip ca-certificates iproute2 procps less \
 && rm -rf /var/lib/apt/lists/*

# 結果を S3 に上げるための AWS CLI v2
RUN case "${TARGETARCH:-amd64}" in arm64) A=aarch64 ;; *) A=x86_64 ;; esac \
 && curl -sSfLo /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-${A}.zip" \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip

COPY lua/ /opt/lab/lua/
COPY bin/ /opt/lab/bin/
RUN chmod +x /opt/lab/bin/*
ENV PATH="/opt/lab/bin:${PATH}"

WORKDIR /results
ENTRYPOINT ["lab"]
CMD ["idle"]
