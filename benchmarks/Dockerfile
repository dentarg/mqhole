FROM ubuntu:26.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libgc1 libssl3t64 libpcre2-8-0 python3 python3-venv openssh-client iproute2 iptables && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir pika==1.3.2 paho-mqtt==2.1.0 rstream==0.40.0
ENV PATH="/opt/venv/bin:$PATH"
CMD ["sleep", "infinity"]
