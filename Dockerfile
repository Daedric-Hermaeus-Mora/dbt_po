FROM python:3.12-slim

# The installer requires curl (and certificates) to download the release archive
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates

# Download the latest installer
ADD https://astral.sh/uv/0.7.2/install.sh /uv-installer.sh

# Run the installer then remove it
RUN sh /uv-installer.sh && rm /uv-installer.sh

# Ensure the installed binary is on the `PATH`
ENV PATH="/root/.local/bin/:$PATH"

# Set working directory
WORKDIR /usr/app/dbt

# Copy project files
#COPY uv.lock ./
COPY pyproject.toml ./
COPY po_dbt/ ./

# Create profiles directory
RUN mkdir -p /root/.dbt/

# Copy profiles.yml (you'll need to create this file with your database credentials)
COPY profiles.yml /root/.dbt/profiles.yml

# Install dbt dependencies
RUN uv sync  --no-dev
RUN uv run dbt deps

# Set the default command
CMD ["uv", "run", "dbt"]