# public.ecr.aws mirror of the official image: avoids Docker Hub pull limits on shared CodeBuild IPs
FROM public.ecr.aws/docker/library/python:3.12-slim

ENV PIP_NO_CACHE_DIR=1 PYTHONUNBUFFERED=1

WORKDIR /app
# Wheels are pre-downloaded by scripts/build-image.sh (optionally through a private package proxy
# the build agent can't reach). Install offline only.
COPY wheels/ /tmp/wheels/
COPY requirements.txt .
RUN pip install --no-index --find-links=/tmp/wheels -r requirements.txt && rm -rf /tmp/wheels
COPY seed_data.py auth.py server.py rest_apis.py ./

RUN useradd --uid 10001 --no-create-home app
USER 10001
EXPOSE 8080
CMD ["python", "server.py"]
