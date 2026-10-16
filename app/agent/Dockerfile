FROM python:3.12-slim

WORKDIR /app

COPY app/agent/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/agent/src/agent/ .

EXPOSE 8000
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
