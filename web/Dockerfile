FROM python:3.12-alpine
# TITIAN web UI operator (Fase 2 langkah 4) — Python stdlib saja, tanpa pip.
WORKDIR /app
COPY titian-web.py /app/
COPY static /app/static/
RUN mkdir -p /data && adduser -D -u 10001 titian && chown -R titian:titian /app /data
USER titian
ENV TITIAN_WEB_DATA=/data TITIAN_WEB_PORT=9091
EXPOSE 9091
CMD ["python3", "/app/titian-web.py", "serve", "--data", "/data", "--port", "9091"]
