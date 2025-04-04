FROM pytorch/pytorch:2.3.1-cuda12.1-cudnn8-runtime

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-download the model during the build process
# First set up a proper directory for the model cache
RUN mkdir -p /app/.torch/hub/checkpoints
ENV TORCH_HOME=/app/.torch

# Ensure we have the proper Python packages needed for downloading
RUN pip install --no-cache-dir requests tqdm

# Create a script to download the model
RUN echo '#!/usr/bin/env python3\n\
import torch\n\
import os\n\
import sys\n\
\n\
# Set up model directory\n\
os.makedirs("/app/.torch/hub/checkpoints", exist_ok=True)\n\
os.environ["TORCH_HOME"] = "/app/.torch"\n\
\n\
print(f"Torch home: {os.environ.get(\"TORCH_HOME\", \"Not set\")}")\n\
\n\
try:\n\
    print("Available models:", torch.hub.list("pytorch/vision"))\n\
    print("Downloading model...")\n\
    model = torch.hub.load("pytorch/vision", "deeplabv3_resnet50", pretrained=True)\n\
    print("Model downloaded successfully")\n\
    # Save the model state to ensure it persists\n\
    torch.save(model.state_dict(), "/app/.torch/hub/deeplabv3_resnet50_state.pth")\n\
    print("Model state saved")\n\
    sys.exit(0)\n\
except Exception as e:\n\
    print(f"Error downloading model: {e}")\n\
    sys.exit(1)\n\
' > /app/download_model.py && chmod +x /app/download_model.py

# Run the script to download the model with several retries
RUN for i in $(seq 1 3); do \
      echo "Attempt $i to download model..." && \
      python /app/download_model.py && break || \
      echo "Download attempt $i failed, retrying in 5 seconds..." && \
      sleep 5; \
    done

# Verify the model files exist
RUN ls -la /app/.torch/hub/checkpoints/ || echo "Warning: Model files not found"

# Copy the application code
COPY . .

# Create uploads directory if it doesn't exist
RUN mkdir -p static/uploads

# Make the uploads directory writable
RUN chmod -R 777 static/uploads

# Set environment variables
ENV FLASK_APP=app.py
ENV FLASK_ENV=production
# TORCH_HOME already set above

# Expose the port
EXPOSE 5000

# Set up directory for logs
RUN mkdir -p /app/logs && chmod 777 /app/logs

# Configure Gunicorn for better debugging and error capture
# - timeout 300: Increase worker timeout to 300 seconds (5 minutes)
# - workers 1: Use only 1 worker to maximize GPU memory available to each worker
# - threads 4: Use multithreading for better performance
# - worker-class gthread: Use threaded worker class
# - capture-output: Capture stdout/stderr from workers
# - enable-stdio-inheritance: Pass through stdout/stderr
# - log-level debug: Show detailed logs
# - error-logfile: Write errors to file
# - access-logfile: Log all access requests
CMD ["gunicorn", "--bind", "0.0.0.0:5000", \
     "--timeout", "300", \
     "--workers", "1", \
     "--threads", "4", \
     "--worker-class", "gthread", \
     "--capture-output", \
     "--enable-stdio-inheritance", \
     "--log-level", "debug", \
     "--error-logfile", "/app/logs/gunicorn-error.log", \
     "--access-logfile", "/app/logs/gunicorn-access.log", \
     "--log-file", "/app/logs/gunicorn.log", \
     "app:app"]