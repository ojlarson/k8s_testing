import os

from fastapi import FastAPI

app = FastAPI()

kube_pod_name = os.getenv("KUBE_POD_NAME", "test")
app_env = os.getenv("APP_ENV", "test")


@app.get("/")
async def root():
    return {"message": f"Hello World from {app_env}"}


# For kubernetes
@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
