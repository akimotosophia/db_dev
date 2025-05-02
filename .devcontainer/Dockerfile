FROM python:3.13-slim

# OS tools
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Python packages
RUN pip install --upgrade pip && pip install \
    psycopg2-binary \
    clickhouse-connect \
    ipython \
    pandas

# Create workspace dir
WORKDIR /workspace
