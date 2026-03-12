# Backend Dockerfile for Gemini Live
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
# DEBIAN_FRONTEND=noninteractive suppresses debconf "TERM not set" warnings
# that appear when apt-get runs in a non-interactive build environment.
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create non-root user (UID 1001 must match deployment.yaml securityContext)
RUN addgroup --system --gid 1001 appgroup && \
    adduser --system --uid 1001 --gid 1001 --no-create-home appuser

# Copy application code
COPY . .

RUN chown -R appuser:appgroup /app
USER appuser

# Expose port
EXPOSE 8080

# Set environment variables
ENV PYTHONUNBUFFERED=1
ENV PORT=8080

# Run the application with uvicorn directly (production mode)
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
