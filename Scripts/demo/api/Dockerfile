# The Acme Shop API image, built by `Scripts/demo-scenario.sh up` so the demo has one image
# of its own among the pulled ones.
FROM docker.io/library/python:3.13-alpine
WORKDIR /app
COPY app.py .
EXPOSE 8000
CMD ["python", "app.py"]
