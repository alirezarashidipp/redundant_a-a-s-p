from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from src.api.routers.grooming import router as grooming_router
from src.api.routers.jira import router as jira_router
from src.api.routers.process import router as process_router
from src.api.routers.static_pages import router as static_pages_router
from src.api.routers.user import router as user_router


BASE_DIR = Path(_file_).resolve().parents[1]
STATIC_DIR BASE_DIR / "static"



@asynccontextmanager
async def lifespan (app: FastAPI):
    from sqlalchemy import text
    from src.config.database import get_engine
    engine = get_engine()
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))
    yield
    #shutdown: close DB engine and all pooled httpx clients cleanly
    await engine.dispose()
    from src.integrations.llm_client import_pool
    for client in pool.values():
        client.close()




def create_app() -> FastAPI:
    app FastAPI(lifespan lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
    app.include_router(static_pages_router)
    app.include_router(process_router)
    app.include_router(jira_router)
    app.include_router(grooming_router)
    app.include_router(user_router)
    
    return app
