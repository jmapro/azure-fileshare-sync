FROM ubuntu:latest

# Install Azure CLI
RUN apt-get update && \
    apt-get install -y curl ca-certificates apt-transport-https lsb-release gnupg wget jq bind9-host && \
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    apt-get autoremove && apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install AzCopy
RUN wget https://aka.ms/downloadazcopy-v10-linux && \ 
    tar xzf downloadazcopy-v10-linux && \
    mv azcopy_linux_amd64*/azcopy /usr/local/bin/ && \
    rm -rf azcopy_linux_amd64* && \
    rm downloadazcopy-v10-linux


COPY --chown=root:root sync-shares.sh /usr/local/bin/
