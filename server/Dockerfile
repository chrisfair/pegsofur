FROM python:3.12-alpine
WORKDIR /app
COPY pegsofur_server.py /app/pegsofur_server.py
RUN mkdir -p /data && chown -R 65534:65534 /data /app
USER 65534:65534
ENV PEGSOFUR_DB_PATH=/data/pegsofur.db
ENV PORT=8092
EXPOSE 8092
CMD ["python3", "/app/pegsofur_server.py"]
