# Container for the Groove Player webapp (Hugging Face Spaces / any Docker host).
FROM python:3.12-slim

# Native libs librosa/soundfile need at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsndfile1 ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Hugging Face Spaces expects the app on 7860. Writable dirs go to /tmp because
# the app directory is read-only on Spaces.
ENV PORT=7860 \
    MGM_CACHE=/tmp/_cache \
    MGM_USER=/tmp/user_grooves.json \
    NUMBA_CACHE_DIR=/tmp/numba \
    MPLCONFIGDIR=/tmp/mpl

EXPOSE 7860
CMD ["python", "webapp.py"]
