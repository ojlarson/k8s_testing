FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
RUN python app/ak_pts_to_parquet.py

RUN useradd --create-home appuser
USER appuser
RUN python -c "import duckdb; duckdb.connect().execute('INSTALL spatial;')"


EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]