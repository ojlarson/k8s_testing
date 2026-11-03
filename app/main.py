from fastapi import FastAPI
import os

app = FastAPI()

kube_pod_name = os.getenv("KUBE_POD_NAME", 'test')

@app.get("/")
async def root():
    return {"message": f"Hello World from {kube_pod_name}"}


# For kubernetes
@app.get("/healthz")
async def healthz():
    return {"status": "ok"}
