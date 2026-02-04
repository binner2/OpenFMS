# Use an official Python runtime as a parent image
FROM python:3.9-slim

# Set the working directory in the container
WORKDIR /app

# Install system dependencies required for psycopg2 and other packages
RUN apt-get update && apt-get install -y \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy the requirements file into the container at /app
COPY requirements.txt ./

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy the current directory contents into the container at /app
COPY . .

# Set python path to allow imports from root and submodules
ENV PYTHONPATH=/app:/app/submodules

# --- PATCHING ---
# 1. Fix Hardcoded 'localhost' in FmRobotSimulator.py
RUN sed -i 's|self.mqtt_client.connect("localhost", 1883, 60)|self.mqtt_client.connect(os.environ.get("MQTT_BROKER", "mqtt"), int(os.environ.get("MQTT_PORT", 1883)), 60)|g' fleet_management/FmRobotSimulator.py

# 2. Patch config.yaml for Docker networking (localhost -> db/mqtt)
RUN sed -i 's|broker_address: "localhost"|broker_address: "mqtt"|g' config/config.yaml && \
    sed -i 's|host: "localhost"|host: "db"|g' config/config.yaml

# Default command
CMD ["python3", "fleet_management/FmMain.py"]
